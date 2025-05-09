/******************************************************************************
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
******************************************************************************/

#include <cub/cub.cuh>
#include <tuple>
#include <type_traits>

#include "sparse_block_bucketize_features_utils.h"
#include "utils.h"

using Tensor = at::Tensor;

namespace dyn_emb {

__forceinline__ __device__ int atomicAdd(int *address, int val) {
  return ::atomicAdd(address, val);
}

__forceinline__ __device__ long atomicAdd(long *address, long val) {
  return (long)::atomicAdd((unsigned long long *)address,
                           (unsigned long long)val);
}

__forceinline__ __device__ long long atomicAdd(long long *address,
                                               long long val) {
  return (long long)::atomicAdd((unsigned long long *)address,
                                (unsigned long long)val);
}

__forceinline__ __device__ unsigned long atomicAdd(unsigned long *address,
                                                   unsigned long val) {
  return (unsigned long)::atomicAdd((unsigned long long *)address,
                                    (unsigned long long)val);
}

__forceinline__ __device__ uint32_t atomicCAS(uint32_t *address,
                                              uint32_t compare, uint32_t val) {
  return (uint32_t)::atomicCAS((unsigned int *)address, (unsigned int)compare,
                               (unsigned int)val);
}

__forceinline__ __device__ int32_t atomicCAS(int32_t *address, int32_t compare,
                                             int32_t val) {
  return (int32_t)::atomicCAS((int *)address, (int)compare, (int)val);
}

__forceinline__ __device__ uint64_t atomicCAS(uint64_t *address,
                                              uint64_t compare, uint64_t val) {
  return (uint64_t)::atomicCAS((unsigned long long *)address,
                               (unsigned long long)compare,
                               (unsigned long long)val);
}

__forceinline__ __device__ int64_t atomicCAS(int64_t *address, int64_t compare,
                                             int64_t val) {
  return (int64_t)::atomicCAS((unsigned long long *)address,
                              (unsigned long long)compare,
                              (unsigned long long)val);
}

Tensor native_empty_like(const Tensor &self) {
  return at::native::empty_like(
      self, c10::optTypeMetaToScalarType(self.options().dtype_opt()),
      self.options().layout_opt(), self.options().device_opt(),
      self.options().pinned_memory_opt(), c10::nullopt);
}
// 1D exclusive scan: output[i] = input[i-1] + input[i-2] + input[i-3]
// Used as a helper to several functions below.
template <class T, class U>
U exclusive_scan_ptrs_cpu(const int64_t N, const T *const input,
                          U *const output) {
  U cumsum = 0;
  for (const auto i : c10::irange(N)) {
    output[i] = cumsum;
    cumsum += input[i];
  }
  return cumsum;
}

Tensor asynchronous_exclusive_cumsum_cpu(const Tensor &t_in) {
  TENSOR_ON_CPU(t_in);

  const auto t_in_contig = t_in.expect_contiguous();
  auto output = native_empty_like(*t_in_contig);
  DYNAMICEMB_DISPATCH_TORCH_ALL_TYPES(
      t_in_contig->scalar_type(), "asynchronous_exclusive_cumsum_cpu_kernel",
      [&] {
        exclusive_scan_ptrs_cpu(t_in_contig->numel(),
                                t_in_contig->data_ptr<scalar_t>(),
                                output.data_ptr<scalar_t>());
      });
  return output;
}

DLL_PUBLIC Tensor asynchronous_exclusive_cumsum_gpu(const Tensor &t_in) {

  CUDA_DEVICE_GUARD(t_in);

  if (t_in.numel() == 0) {
    return at::empty_like(t_in);
  }

  size_t temp_storage_bytes = 0;
  TORCH_CHECK(t_in.is_contiguous());
  TORCH_CHECK(t_in.dtype() == at::kInt || t_in.dtype() == at::kLong);
  // CUB only handles up to INT_MAX elements.
  TORCH_CHECK(t_in.numel() < std::numeric_limits<int32_t>::max());
  auto t_out = at::empty_like(t_in);

  AT_DISPATCH_INDEX_TYPES(
      t_in.scalar_type(), "cub_exclusive_sum_wrapper1", [&] {
        AT_CUDA_CHECK(cub::DeviceScan::ExclusiveSum(
            nullptr, temp_storage_bytes, t_in.data_ptr<index_t>(),
            t_out.data_ptr<index_t>(), t_in.numel(),
            at::cuda::getCurrentCUDAStream()));
      });

  auto temp_storage = at::empty({static_cast<int64_t>(temp_storage_bytes)},
                                t_in.options().dtype(at::kByte));

  AT_DISPATCH_INDEX_TYPES(
      t_in.scalar_type(), "cub_exclusive_sum_wrapper2", [&] {
        AT_CUDA_CHECK(cub::DeviceScan::ExclusiveSum(
            temp_storage.data_ptr(), temp_storage_bytes,
            t_in.data_ptr<index_t>(), t_out.data_ptr<index_t>(), t_in.numel(),
            at::cuda::getCurrentCUDAStream()));
      });

  return t_out;
}

DLL_PUBLIC Tensor asynchronous_inclusive_cumsum_gpu(const Tensor &t_in) {
  TENSOR_ON_CUDA_GPU(t_in);
  CUDA_DEVICE_GUARD(t_in);

  if (t_in.numel() == 0) {
    return at::empty_like(t_in);
  }

  size_t temp_storage_bytes = 0;
  TORCH_CHECK(t_in.is_contiguous());
  TORCH_CHECK(t_in.dtype() == at::kInt || t_in.dtype() == at::kLong);
  // CUB only handles up to INT_MAX elements.
  TORCH_CHECK(t_in.numel() < std::numeric_limits<int32_t>::max());
  auto t_out = at::empty_like(t_in);

  AT_DISPATCH_INDEX_TYPES(
      t_in.scalar_type(), "cub_inclusive_sum_wrapper1", [&] {
        AT_CUDA_CHECK(cub::DeviceScan::InclusiveSum(
            nullptr, temp_storage_bytes, t_in.data_ptr<index_t>(),
            t_out.data_ptr<index_t>(), t_in.numel(),
            at::cuda::getCurrentCUDAStream()));
      });

  auto temp_storage = at::empty({static_cast<int64_t>(temp_storage_bytes)},
                                t_in.options().dtype(at::kByte));

  AT_DISPATCH_INDEX_TYPES(
      t_in.scalar_type(), "cub_inclusive_sum_wrapper2", [&] {
        AT_CUDA_CHECK(cub::DeviceScan::InclusiveSum(
            temp_storage.data_ptr(), temp_storage_bytes,
            t_in.data_ptr<index_t>(), t_out.data_ptr<index_t>(), t_in.numel(),
            at::cuda::getCurrentCUDAStream()));
      });

  return t_out;
}

// Kernel for calculating length idx to feature id mapping. Used for block
// bucketize sparse features with variable batch size for row-wise partition
template <typename offset_t>
__global__
__launch_bounds__(kMaxThreads) void _populate_length_to_feature_id_inplace_kernel(
    const uint64_t max_B, const int T,
    const offset_t *const __restrict__ batch_size_per_feature,
    const offset_t *const __restrict__ batch_size_offsets,
    offset_t *const __restrict__ length_to_feature_idx) {
  const auto b_t = blockIdx.x * blockDim.x + threadIdx.x;

  const auto t = b_t / max_B;
  const auto b = b_t % max_B;

  if (t >= T || b >= batch_size_per_feature[t]) {
    return;
  }

  length_to_feature_idx[batch_size_offsets[t] + b] = t;
}

// Kernel for bucketize lengths, with the Block distribution (vs. cyclic,
// block-cyclic distribution). Used for bucketize sparse feature, especially for
// checkpointing with row-wise partition (sparse_feature is partitioned
// continuously along the sparse dimension into my_size blocks)
template <typename offset_t, typename index_t>
__global__
__launch_bounds__(kMaxThreads) void _block_bucketize_sparse_features_cuda_kernel1(
    const int32_t lengths_size, const int32_t B,
    const index_t *const __restrict__ block_sizes_data, const int my_size,
    const offset_t *const __restrict__ offsets_data,
    const index_t *const __restrict__ indices_data,
    offset_t *const __restrict__ new_lengths_data,
    offset_t *__restrict__ length_to_feature_idx,
    const offset_t *const __restrict__ block_bucketize_pos_concat,
    const offset_t *const __restrict__ block_bucketize_pos_offsets,
    offset_t *__restrict__ indices_to_lb,
    // bool use_roundrobin) {
    const int32_t *__restrict__ dist_type_per_feature) {
  using uindex_t = std::make_unsigned_t<index_t>;
  const auto bt_start = blockIdx.x * blockDim.y + threadIdx.y;
  const auto stride = gridDim.x * blockDim.y;
  for (auto b_t = bt_start; b_t < lengths_size; b_t += stride) {
    const auto t = length_to_feature_idx ? length_to_feature_idx[b_t] : b_t / B;
    bool use_roundrobin =
        dist_type_per_feature ? dist_type_per_feature[t] : false;
    index_t blk_size = block_sizes_data[t];
    offset_t rowstart = (b_t == 0 ? 0 : offsets_data[b_t - 1]);
    offset_t rowend = offsets_data[b_t];
    const auto use_block_bucketize_pos =
        (block_bucketize_pos_concat != nullptr);
    // We have use cases using none-hashed raw indices that can be either
    // negative or larger than embedding table hash_size (blk_size *
    // my_size). In cases of none-hashed indices we need to ensure
    // bucketization can distribute them into different ranks and within
    // range of blk_size, we expect the later embedding module to take care
    // of hashing indices calculation.
    if (!use_block_bucketize_pos) {
      for (auto i = rowstart + threadIdx.x; i < rowend; i += blockDim.x) {
        uindex_t idx = static_cast<uindex_t>(indices_data[i]);
        uindex_t p = 0;
        if (use_roundrobin) {

          p = idx % my_size;
        } else {
          p = idx < blk_size * my_size ? idx / blk_size : idx % my_size;
        }
        atomicAdd(&new_lengths_data[p * lengths_size + b_t], 1);
      }
      return;
    }

    for (auto i = rowstart + threadIdx.x; i < rowend; i += blockDim.x) {
      uindex_t idx = static_cast<uindex_t>(indices_data[i]);
      uindex_t p = 0;
      index_t first = block_bucketize_pos_offsets[t];
      index_t last = block_bucketize_pos_offsets[t + 1];

      while (first < last) {
        index_t middle = first + ((last - first) / 2);
        if (static_cast<uindex_t>(block_bucketize_pos_concat[middle]) <= idx) {
          first = ++middle;
        } else {
          last = middle;
        }
      }
      uindex_t lb =
          static_cast<uindex_t>(first - block_bucketize_pos_offsets[t] - 1);
      indices_to_lb[i] = lb;
      p = lb < my_size ? lb : idx % my_size;
      atomicAdd(&new_lengths_data[p * lengths_size + b_t], 1);
    }
  }
}

// Kernel for bucketize offsets, indices, and positional weights, with the Block
// distribution (vs. cyclic, block-cyclic distribution). Used for bucketize
// sparse feature, especially for checkpointing with row-wise partition
// (sparse_feature is partitioned continuously along the sparse dimension into
// my_size blocks)
template <bool sequence, bool has_weight, bool bucketize_pos, typename offset_t,
          typename index_t, typename scalar_t>
__global__
__launch_bounds__(kMaxThreads) void _block_bucketize_sparse_features_cuda_kernel2(
    int lengths_size, int32_t B, const index_t *__restrict__ block_sizes_data,
    int my_size, const offset_t *__restrict__ offsets_data,
    const index_t *__restrict__ indices_data,
    const scalar_t *__restrict__ weights_data,
    offset_t *__restrict__ new_offsets_data,
    index_t *__restrict__ new_indices_data,
    scalar_t *__restrict__ new_weights_data, index_t *__restrict__ new_pos_data,
    index_t *const __restrict__ unbucketize_permute_data,
    const offset_t *const __restrict__ length_to_feature_idx,
    const offset_t *const __restrict__ block_bucketize_pos_concat,
    const offset_t *const __restrict__ block_bucketize_pos_offsets,
    // const offset_t* const __restrict__ indices_to_lb,bool use_roundrobin) {
    const offset_t *const __restrict__ indices_to_lb,
    const int32_t *__restrict__ dist_type_per_feature) {
  using uindex_t = std::make_unsigned_t<index_t>;
  using uoffset_t = std::make_unsigned_t<offset_t>;
  CUDA_1D_KERNEL_LOOP(b_t, lengths_size) {
    const auto t = length_to_feature_idx ? length_to_feature_idx[b_t] : b_t / B;
    bool use_roundrobin =
        dist_type_per_feature ? dist_type_per_feature[t] : false;
    index_t blk_size = block_sizes_data[t];
    offset_t rowstart = (b_t == 0 ? 0 : offsets_data[b_t - 1]);
    offset_t rowend = offsets_data[b_t];
    const auto use_block_bucketize_pos =
        (block_bucketize_pos_concat != nullptr);
    for (index_t i = rowstart; i < rowend; ++i) {
      // We have use cases using none-hashed raw indices that can be either
      // negative or larger than embedding table hash_size (blk_size *
      // my_size). In cases of none-hashed indices we need to ensure
      // bucketization can distribute them into different ranks and within
      // range of blk_size, we expect the later embedding module to take care
      // of hashing indices calculation.
      uindex_t idx = static_cast<uindex_t>(indices_data[i]);
      uindex_t p = 0;
      uindex_t new_idx = 0;
      if (!use_block_bucketize_pos) {
        if (use_roundrobin) {
          p = idx % my_size;
          new_idx = idx;
        } else {
          p = idx < blk_size * my_size ? idx / blk_size : idx % my_size;
          new_idx = idx < blk_size * my_size ? idx % blk_size : idx / my_size;
        }
      } else {
        uindex_t lb = indices_to_lb[i];
        p = lb < my_size ? lb : idx % my_size;
        new_idx =
            lb < my_size
                ? idx -
                      block_bucketize_pos_concat[lb +
                                                 block_bucketize_pos_offsets[t]]
                : idx / my_size;
      }
      uoffset_t pos = new_offsets_data[p * lengths_size + b_t];
      new_indices_data[pos] = new_idx;
      new_offsets_data[p * lengths_size + b_t]++;
      if (sequence) {
        unbucketize_permute_data[i] = pos;
      }
      if (has_weight) {
        new_weights_data[pos] = weights_data[i];
      }
      if (bucketize_pos) {
        new_pos_data[pos] = i - rowstart;
      }
    }
  }
}

// This function partitions sparse features
// continuously along the sparse dimension into my_size blocks
DLL_PUBLIC std::tuple<Tensor, Tensor, c10::optional<Tensor>,
                      c10::optional<Tensor>, c10::optional<Tensor>>
block_bucketize_sparse_features_cuda(
    const Tensor &lengths, const Tensor &indices, const bool bucketize_pos,
    const bool sequence,
    // const bool use_roundrobin,
    const Tensor &dist_type_per_feature, const Tensor &block_sizes,
    const int64_t my_size, const c10::optional<Tensor> &weights,
    const c10::optional<Tensor> &batch_size_per_feature, const int64_t max_B,
    const c10::optional<std::vector<at::Tensor>> &block_bucketize_pos) {
  TENSORS_ON_SAME_CUDA_GPU_IF_NOT_OPTIONAL(lengths, indices);

  CUDA_DEVICE_GUARD(lengths);

  // allocate tensors and buffers
  const auto lengths_size = lengths.numel();
  const auto T = block_sizes.numel();
  const auto B = lengths_size / T;
  const auto new_lengths_size = lengths_size * my_size;
  auto offsets = at::empty({lengths_size}, lengths.options());
  auto new_lengths = at::zeros({new_lengths_size}, lengths.options());
  auto new_offsets = at::empty({new_lengths_size}, lengths.options());
  auto new_indices = at::empty_like(indices);
  auto lengths_contig = lengths.contiguous();
  auto indices_contig = indices.contiguous();
  auto offsets_contig = offsets.contiguous();
  auto batch_sizes_contig =
      batch_size_per_feature.value_or(at::empty({T}, lengths.options()))
          .contiguous();
  auto batch_sizes_offsets_contig =
      at::empty({T}, batch_sizes_contig.options());
  Tensor new_weights;
  Tensor new_pos;
  Tensor unbucketize_permute;
  // count nonzeros
  offsets_contig = asynchronous_inclusive_cumsum_gpu(lengths);
  if (batch_size_per_feature.has_value()) {
    TORCH_CHECK(max_B > 0);
    batch_sizes_offsets_contig =
        asynchronous_exclusive_cumsum_gpu(batch_size_per_feature.value());
  }
  auto length_to_feature_idx =
      at::empty({lengths_size}, lengths_contig.options());
  auto indices_to_lb = at::empty_like(indices);
  if (batch_size_per_feature.has_value()) {
    constexpr auto threads_per_block = 256;
    const auto num_blocks =
        cuda_calc_xblock_count(max_B * T, threads_per_block);
    AT_DISPATCH_INDEX_TYPES(
        offsets_contig.scalar_type(),
        "_populate_length_to_feature_id_inplace_kernel", [&] {
          using offset_t = index_t;
          _populate_length_to_feature_id_inplace_kernel<<<
              num_blocks, threads_per_block, 0,
              at::cuda::getCurrentCUDAStream()>>>(
              max_B, T, batch_sizes_contig.data_ptr<offset_t>(),
              batch_sizes_offsets_contig.data_ptr<offset_t>(),
              length_to_feature_idx.data_ptr<offset_t>());
          C10_CUDA_KERNEL_LAUNCH_CHECK();
        });
  }

  at::Tensor block_bucketize_pos_concat =
      at::empty({1}, lengths_contig.options());
  at::Tensor block_bucketize_pos_offsets =
      at::empty({1}, lengths_contig.options());

  if (block_bucketize_pos.has_value()) {
    block_bucketize_pos_concat = at::cat(block_bucketize_pos.value(), 0);
    std::vector<int64_t> sizes_;
    sizes_.reserve(block_bucketize_pos.value().size() + 1);
    for (auto const &t : block_bucketize_pos.value()) {
      sizes_.push_back(t.numel());
    }
    sizes_.push_back(0);
    at::Tensor sizes_vec =
        at::tensor(sizes_, at::TensorOptions().dtype(lengths_contig.dtype()));
    block_bucketize_pos_offsets = asynchronous_exclusive_cumsum_cpu(
        sizes_vec); // expect sizes_vec to be a small tensor, using cpu instead
                    // of gpu for cumsum
    block_bucketize_pos_offsets = block_bucketize_pos_offsets.to(
        block_bucketize_pos_concat.device(), true);
  }
  static_assert(kMaxThreads % kWarpSize == 0);
  const dim3 block_dims(kWarpSize, kMaxThreads / kWarpSize);
  const dim3 grid_dims(cuda_calc_xblock_count(lengths_size, block_dims.y));
  AT_DISPATCH_INDEX_TYPES(
      offsets_contig.scalar_type(),
      "_block_bucketize_sparse_features_cuda_kernel1", [&] {
        using offset_t = index_t;
        AT_DISPATCH_INDEX_TYPES(
            indices_contig.scalar_type(),
            "_block_bucketize_sparse_features_cuda_kernel2", [&] {
              _block_bucketize_sparse_features_cuda_kernel1<<<
                  grid_dims, block_dims, 0, at::cuda::getCurrentCUDAStream()>>>(
                  lengths_size, B, block_sizes.data_ptr<index_t>(), my_size,
                  offsets_contig.data_ptr<offset_t>(),
                  indices_contig.data_ptr<index_t>(),
                  new_lengths.data_ptr<offset_t>(),
                  batch_size_per_feature.has_value()
                      ? length_to_feature_idx.data_ptr<offset_t>()
                      : static_cast<offset_t *>(nullptr),
                  block_bucketize_pos.has_value()
                      ? block_bucketize_pos_concat.data_ptr<offset_t>()
                      : static_cast<offset_t *>(nullptr),
                  block_bucketize_pos.has_value()
                      ? block_bucketize_pos_offsets.data_ptr<offset_t>()
                      : static_cast<offset_t *>(nullptr),
                  block_bucketize_pos.has_value()
                      ? indices_to_lb.data_ptr<offset_t>()
                      : static_cast<offset_t *>(nullptr),
                  dist_type_per_feature.data_ptr<int32_t>());
              C10_CUDA_KERNEL_LAUNCH_CHECK();
            });
      });
  constexpr auto threads_per_block = 256;
  const auto num_blocks =
      cuda_calc_xblock_count(lengths_size, threads_per_block);
  // bucketize nonzeros
  new_offsets = asynchronous_exclusive_cumsum_gpu(new_lengths);
  if (sequence) {
    const auto lengths_sum = indices.numel();
    unbucketize_permute = at::empty({lengths_sum}, indices.options());
    if (weights.has_value() & bucketize_pos) {
      Tensor weights_value = weights.value();
      auto weights_value_contig = weights_value.contiguous();
      new_weights = at::empty_like(weights_value);
      new_pos = at::empty_like(indices);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_bucketize_sparse_features_weight_cuda_kernel2_2", [&] {
                  DYNAMICEMB_AT_DISPATCH_FLOAT_ONLY(
                      weights_value.scalar_type(),
                      "_block_bucketize_sparse_features_cuda_weight_kernel2_3",
                      [&] {
                        _block_bucketize_sparse_features_cuda_kernel2<
                            true, true, true, offset_t, index_t, scalar_t>
                            <<<num_blocks, threads_per_block, 0,
                               at::cuda::getCurrentCUDAStream()>>>(
                                lengths_size, B,
                                block_sizes.data_ptr<index_t>(), my_size,
                                offsets_contig.data_ptr<offset_t>(),
                                indices_contig.data_ptr<index_t>(),
                                weights_value_contig.data_ptr<scalar_t>(),
                                new_offsets.data_ptr<offset_t>(),
                                new_indices.data_ptr<index_t>(),
                                new_weights.data_ptr<scalar_t>(),
                                new_pos.data_ptr<index_t>(),
                                unbucketize_permute.data_ptr<index_t>(),
                                batch_size_per_feature.has_value()
                                    ? length_to_feature_idx.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_concat
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_offsets
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? indices_to_lb.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                dist_type_per_feature.data_ptr<int32_t>());
                        C10_CUDA_KERNEL_LAUNCH_CHECK();
                      });
                });
          });
    } else if (weights.has_value()) {
      Tensor weights_value = weights.value();
      auto weights_value_contig = weights_value.contiguous();
      new_weights = at::empty_like(weights_value);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_bucketize_sparse_features_weight_cuda_kernel2_2", [&] {
                  DYNAMICEMB_AT_DISPATCH_FLOAT_ONLY(
                      weights_value.scalar_type(),
                      "_block_bucketize_sparse_features_cuda_weight_kernel2_3",
                      [&] {
                        _block_bucketize_sparse_features_cuda_kernel2<
                            true, true, false, offset_t, index_t, scalar_t>
                            <<<num_blocks, threads_per_block, 0,
                               at::cuda::getCurrentCUDAStream()>>>(
                                lengths_size, B,
                                block_sizes.data_ptr<index_t>(), my_size,
                                offsets_contig.data_ptr<offset_t>(),
                                indices_contig.data_ptr<index_t>(),
                                weights_value_contig.data_ptr<scalar_t>(),
                                new_offsets.data_ptr<offset_t>(),
                                new_indices.data_ptr<index_t>(),
                                new_weights.data_ptr<scalar_t>(), nullptr,
                                unbucketize_permute.data_ptr<index_t>(),
                                batch_size_per_feature.has_value()
                                    ? length_to_feature_idx.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_concat
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_offsets
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? indices_to_lb.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                dist_type_per_feature.data_ptr<int32_t>());
                        C10_CUDA_KERNEL_LAUNCH_CHECK();
                      });
                });
          });
    } else if (bucketize_pos) {
      new_pos = at::empty_like(indices);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_block_bucketize_sparse_features_cuda_kernel2_2", [&] {
                  _block_bucketize_sparse_features_cuda_kernel2<
                      true, false, true, offset_t, index_t, std::nullptr_t>
                      <<<num_blocks, threads_per_block, 0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          lengths_size, B, block_sizes.data_ptr<index_t>(),
                          my_size, offsets_contig.data_ptr<offset_t>(),
                          indices_contig.data_ptr<index_t>(), nullptr,
                          new_offsets.data_ptr<offset_t>(),
                          new_indices.data_ptr<index_t>(), nullptr,
                          new_pos.data_ptr<index_t>(),
                          unbucketize_permute.data_ptr<index_t>(),
                          batch_size_per_feature.has_value()
                              ? length_to_feature_idx.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_concat.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_offsets.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? indices_to_lb.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          dist_type_per_feature.data_ptr<int32_t>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    } else {
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_block_bucketize_sparse_features_cuda_kernel2_2", [&] {
                  _block_bucketize_sparse_features_cuda_kernel2<
                      true, false, false, offset_t, index_t, std::nullptr_t>
                      <<<num_blocks, threads_per_block, 0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          lengths_size, B, block_sizes.data_ptr<index_t>(),
                          my_size, offsets_contig.data_ptr<offset_t>(),
                          indices_contig.data_ptr<index_t>(), nullptr,
                          new_offsets.data_ptr<offset_t>(),
                          new_indices.data_ptr<index_t>(), nullptr, nullptr,
                          unbucketize_permute.data_ptr<index_t>(),
                          batch_size_per_feature.has_value()
                              ? length_to_feature_idx.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_concat.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_offsets.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? indices_to_lb.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          dist_type_per_feature.data_ptr<int32_t>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    }
  } else {
    if (weights.has_value() & bucketize_pos) {
      Tensor weights_value = weights.value();
      auto weights_value_contig = weights_value.contiguous();
      new_weights = at::empty_like(weights_value);
      new_pos = at::empty_like(indices);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_bucketize_sparse_features_weight_cuda_kernel2_2", [&] {
                  DYNAMICEMB_AT_DISPATCH_FLOAT_ONLY(
                      weights_value.scalar_type(),
                      "_block_bucketize_sparse_features_cuda_weight_kernel2_3",
                      [&] {
                        _block_bucketize_sparse_features_cuda_kernel2<
                            false, true, true, offset_t, index_t, scalar_t>
                            <<<num_blocks, threads_per_block, 0,
                               at::cuda::getCurrentCUDAStream()>>>(
                                lengths_size, B,
                                block_sizes.data_ptr<index_t>(), my_size,
                                offsets_contig.data_ptr<offset_t>(),
                                indices_contig.data_ptr<index_t>(),
                                weights_value_contig.data_ptr<scalar_t>(),
                                new_offsets.data_ptr<offset_t>(),
                                new_indices.data_ptr<index_t>(),
                                new_weights.data_ptr<scalar_t>(),
                                new_pos.data_ptr<index_t>(), nullptr,
                                batch_size_per_feature.has_value()
                                    ? length_to_feature_idx.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_concat
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_offsets
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? indices_to_lb.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                dist_type_per_feature.data_ptr<int32_t>());
                        C10_CUDA_KERNEL_LAUNCH_CHECK();
                      });
                });
          });
    } else if (weights.has_value()) {
      Tensor weights_value = weights.value();
      auto weights_value_contig = weights_value.contiguous();
      new_weights = at::empty_like(weights_value);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_bucketize_sparse_features_weight_cuda_kernel2_2", [&] {
                  DYNAMICEMB_AT_DISPATCH_FLOAT_ONLY(
                      weights_value.scalar_type(),
                      "_block_bucketize_sparse_features_cuda_weight_kernel2_3",
                      [&] {
                        _block_bucketize_sparse_features_cuda_kernel2<
                            false, true, false, offset_t, index_t, scalar_t>
                            <<<num_blocks, threads_per_block, 0,
                               at::cuda::getCurrentCUDAStream()>>>(
                                lengths_size, B,
                                block_sizes.data_ptr<index_t>(), my_size,
                                offsets_contig.data_ptr<offset_t>(),
                                indices_contig.data_ptr<index_t>(),
                                weights_value_contig.data_ptr<scalar_t>(),
                                new_offsets.data_ptr<offset_t>(),
                                new_indices.data_ptr<index_t>(),
                                new_weights.data_ptr<scalar_t>(), nullptr,
                                nullptr,
                                batch_size_per_feature.has_value()
                                    ? length_to_feature_idx.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_concat
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? block_bucketize_pos_offsets
                                          .data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                block_bucketize_pos.has_value()
                                    ? indices_to_lb.data_ptr<offset_t>()
                                    : static_cast<offset_t *>(nullptr),
                                dist_type_per_feature.data_ptr<int32_t>());
                        C10_CUDA_KERNEL_LAUNCH_CHECK();
                      });
                });
          });
    } else if (bucketize_pos) {
      new_pos = at::empty_like(indices);
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_block_bucketize_sparse_features_cuda_kernel2_2", [&] {
                  _block_bucketize_sparse_features_cuda_kernel2<
                      false, false, true, offset_t, index_t, std::nullptr_t>
                      <<<num_blocks, threads_per_block, 0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          lengths_size, B, block_sizes.data_ptr<index_t>(),
                          my_size, offsets_contig.data_ptr<offset_t>(),
                          indices_contig.data_ptr<index_t>(), nullptr,
                          new_offsets.data_ptr<offset_t>(),
                          new_indices.data_ptr<index_t>(), nullptr,
                          new_pos.data_ptr<index_t>(), nullptr,
                          batch_size_per_feature.has_value()
                              ? length_to_feature_idx.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_concat.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_offsets.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? indices_to_lb.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          dist_type_per_feature.data_ptr<int32_t>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    } else {
      AT_DISPATCH_INDEX_TYPES(
          offsets_contig.scalar_type(),
          "_bucketize_sparse_features_weight_cuda_kernel2_1", [&] {
            using offset_t = index_t;
            AT_DISPATCH_INDEX_TYPES(
                indices_contig.scalar_type(),
                "_block_bucketize_sparse_features_cuda_kernel2_2", [&] {
                  _block_bucketize_sparse_features_cuda_kernel2<
                      false, false, false, offset_t, index_t, std::nullptr_t>
                      <<<num_blocks, threads_per_block, 0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          lengths_size, B, block_sizes.data_ptr<index_t>(),
                          my_size, offsets_contig.data_ptr<offset_t>(),
                          indices_contig.data_ptr<index_t>(), nullptr,
                          new_offsets.data_ptr<offset_t>(),
                          new_indices.data_ptr<index_t>(), nullptr, nullptr,
                          nullptr,
                          batch_size_per_feature.has_value()
                              ? length_to_feature_idx.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_concat.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? block_bucketize_pos_offsets.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          block_bucketize_pos.has_value()
                              ? indices_to_lb.data_ptr<offset_t>()
                              : static_cast<offset_t *>(nullptr),
                          dist_type_per_feature.data_ptr<int32_t>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    }
  }

  return {new_lengths, new_indices, new_weights, new_pos, unbucketize_permute};
}

} // namespace dyn_emb

void bind_bucktiz_kernel_op(py::module &m) {

  m.def("block_bucketize_sparse_features",
        &dyn_emb::block_bucketize_sparse_features_cuda,
        "Block bucketize sparse features in CUDA", py::arg("lengths"),
        py::arg("indices"), py::arg("bucketize_pos"), py::arg("sequence"),
        // py::arg("use_roundrobin"),
        py::arg("dist_type_per_feature"), py::arg("block_sizes"),
        py::arg("my_size"), py::arg("weights") = py::none(),
        py::arg("batch_size_per_feature") = py::none(), py::arg("max_B"),
        py::arg("block_bucketize_pos") = py::none());
}

// DYNAMICEMB_OP_DISPATCH(
//     CUDA,
//     "block_bucketize_sparse_features",
//     dyn_emb::block_bucketize_sparse_features_cuda);
