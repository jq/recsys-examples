import argparse
import builtins
import math
import os
import shutil
import urllib.request
import zipfile
from typing import Dict, List

import numpy as np
import pandas as pd
import torch
import torch.distributed as dist
import torch.nn as nn
from dynamicemb import (
    DynamicEmbDump,
    DynamicEmbInitializerArgs,
    DynamicEmbInitializerMode,
    DynamicEmbLoad,
    DynamicEmbScoreStrategy,
    DynamicEmbTableOptions,
)
from dynamicemb.incremental_dump import get_score, incremental_dump
from dynamicemb.planner import (
    DynamicEmbeddingEnumerator,
    DynamicEmbeddingShardingPlanner,
    DynamicEmbParameterConstraints,
)
from dynamicemb.shard import DynamicEmbeddingCollectionSharder
from fbgemm_gpu.split_embedding_configs import EmbOptimType, SparseType
from torch.optim import Adam
from torch.utils.data import DataLoader, Dataset
from torch.utils.data.distributed import DistributedSampler
from torchrec import DataType
from torchrec.distributed.comm import get_local_size
from torchrec.distributed.fbgemm_qcomm_codec import (
    CommType,
    QCommsConfig,
    get_qcomm_codecs_registry,
)
from torchrec.distributed.model_parallel import (
    DefaultDataParallelWrapper,
    DistributedModelParallel,
)
from torchrec.distributed.planner import Topology
from torchrec.distributed.planner.storage_reservations import (
    HeuristicalStorageReservation,
)
from torchrec.distributed.types import ShardingType
from torchrec.modules.embedding_configs import EmbeddingConfig
from torchrec.modules.embedding_modules import EmbeddingCollection
from torchrec.sparse.jagged_tensor import KeyedJaggedTensor

print(f"torch.cuda.device_count() : {torch.cuda.device_count()}")

def parse_args():
    parser = argparse.ArgumentParser(description="TorchRec MovieLens with dynamicemb")
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--dump", action="store_true")
    parser.add_argument("--incremental_dump", action="store_true")

    parser.add_argument(
        "--data_path",
        type=str,
        default="./ml-1m",
        help="path to dataset MovieLens，and will download if non-existed",
    )
    parser.add_argument("--epochs", type=int, default=5, help="training epochs")
    parser.add_argument("--batch_size", type=int, default=1024, help="batch size")
    parser.add_argument("--lr", type=float, default=0.01, help="learning rate")
    parser.add_argument(
        "--embedding_dim", type=int, default=64, help="embedding dimension"
    )
    parser.add_argument(
        "--num_embeddings", type=int, default=10000, help="number of embeddings"
    )
    parser.add_argument(
        "--mlp_dims",
        type=str,
        default="128,64,32",
        help="dimension of MLP layer，separating with commas",
    )
    parser.add_argument(
        "--save_dir",
        type=str,
        default="./model_checkpoints",
        help="path to save the model",
    )
    parser.add_argument(
        "--seed", type=int, default=42, help="random seed used for initialization"
    )
    # 新增多机分布式训练相关参数
    parser.add_argument(
        "--local_rank", type=int, default=int(os.environ.get("LOCAL_RANK", 0)),
        help="local rank within a node"
    )
    parser.add_argument(
        "--local_world_size", type=int, default=int(os.environ.get("LOCAL_WORLD_SIZE", 1)),
        help="number of processes per node"
    )
    parser.add_argument(
        "--node_rank", type=int, default=int(os.environ.get("RANK", 0)),
        help="rank of the current node"
    )
    parser.add_argument(
        "--num_nodes", type=int, default=int(os.environ.get("PET_NNODES", 1)),
        help="number of nodes in the cluster"
    )
    parser.add_argument(
        "--master_addr", type=str, default=os.environ.get("MASTER_ADDR", "localhost"),
        help="master node address"
    )
    parser.add_argument(
        "--master_port", type=str, default=os.environ.get("MASTER_PORT", "29500"),
        help="master node port"
    )
    parser.add_argument(
        "--backend", type=str, default="nccl", help="distributed backend"
    )
    return parser.parse_args()

# 初始化分布式环境
def init_distributed(args):
    # 设置进程组初始化的环境变量
    os.environ["MASTER_ADDR"] = args.master_addr
    os.environ["MASTER_PORT"] = args.master_port

    # 计算全局 rank
    # global_rank = args.node_rank * args.local_world_size + args.local_rank
    # world_size = args.num_nodes * args.local_world_size

    # 初始化进程组
    dist.init_process_group(
        backend=args.backend,
        # world_size=world_size,
        # rank=global_rank,
    )
    world_size = dist.get_world_size()
    global_rank = dist.get_rank()
    # 设置当前设备
    torch.cuda.set_device(args.local_rank)
    device = torch.device(f"cuda:{args.local_rank}")

    # 打印初始化信息
    print(f"Initialized process group: world_size={world_size}, "
          f"local_rank={args.local_rank}, global_rank={global_rank}, "
          f"node_rank={args.node_rank}, device={device}")

    return global_rank, world_size, device

# 增加打印带 rank 信息的函数
def setup_rank_print(global_rank):
    original_print = builtins.print
    def rank_print(*args, **kwargs):
        original_print(f"[RANK {global_rank}] ", *args, **kwargs)
    builtins.print = rank_print

def download_movielens(data_dir="./ml-1m", global_rank=0):
    if global_rank == 0:
        os.makedirs(data_dir, exist_ok=True)
        if os.path.exists(os.path.join(data_dir, "ratings.dat")):
            print(f"MovieLens in {data_dir}")
            return data_dir

        url = "https://files.grouplens.org/datasets/movielens/ml-1m.zip"
        zip_path = os.path.join(data_dir, "ml-1m.zip")

        print(f"download MovieLens-1M...")
        urllib.request.urlretrieve(url, zip_path)

        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            zip_ref.extractall(os.path.dirname(data_dir))

        extracted_dir = os.path.join(os.path.dirname(data_dir), "ml-1m")
        if extracted_dir != data_dir:
            for file in os.listdir(extracted_dir):
                shutil.move(
                    os.path.join(extracted_dir, file), os.path.join(data_dir, file)
                )
            if os.path.exists(extracted_dir):
                shutil.rmtree(extracted_dir)

        os.remove(zip_path)

    return data_dir

class MovieLensDataset(Dataset):
    def __init__(self, data_path: str, split: str = "train"):
        ratings_file = os.path.join(data_path, "ratings.dat")
        if not os.path.exists(ratings_file):
            raise FileNotFoundError(f": {ratings_file}")

        ratings_data = []
        with open(ratings_file, "r", encoding="ISO-8859-1") as f:
            for line in f:
                user_id, movie_id, rating, timestamp = line.strip().split("::")
                ratings_data.append(
                    {
                        "user_id": int(user_id),
                        "movie_id": int(movie_id),
                        "rating": float(rating),
                        "timestamp": int(timestamp),
                    }
                )

        ratings_df = pd.DataFrame(ratings_data)

        users_file = os.path.join(data_path, "users.dat")
        movies_file = os.path.join(data_path, "movies.dat")

        users_data = []
        with open(users_file, "r", encoding="ISO-8859-1") as f:
            for line in f:
                parts = line.strip().split("::")
                user_id = int(parts[0])
                gender = 1 if parts[1] == "M" else 0
                age = int(parts[2])
                occupation = int(parts[3])
                users_data.append(
                    {
                        "user_id": user_id,
                        "gender": gender,
                        "age": age,
                        "occupation": occupation,
                    }
                )

        users_df = pd.DataFrame(users_data)

        movies_data = []
        with open(movies_file, "r", encoding="ISO-8859-1") as f:
            for line in f:
                parts = line.strip().split("::")
                movie_id = int(parts[0])
                year = 0
                if parts[1].endswith(")"):
                    year_start = parts[1].rfind("(")
                    if year_start != -1:
                        year_str = parts[1][year_start + 1 : parts[1].rfind(")")]
                        try:
                            year = int(year_str)
                        except ValueError:
                            year = 0

                movies_data.append({"movie_id": movie_id, "year": year})

        movies_df = pd.DataFrame(movies_data)

        data = pd.merge(ratings_df, users_df, on="user_id", how="left")
        data = pd.merge(data, movies_df, on="movie_id", how="left")

        data = data.sort_values("timestamp")

        split_idx = int(len(data) * 0.8)
        if split == "train":
            self.data = data.iloc[:split_idx]
        else:
            self.data = data.iloc[split_idx:]

        self.max_user_id = data["user_id"].max()
        self.max_movie_id = data["movie_id"].max()
        self.max_age = data["age"].max()
        self.max_occupation = data["occupation"].max()

        print(f": {len(self.data)} ")
        print(f": {self.max_user_id}, : {self.max_movie_id}")

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        row = self.data.iloc[idx]

        sparse_features = {
            "user_id": torch.tensor([row["user_id"]], dtype=torch.long),
            "movie_id": torch.tensor([row["movie_id"]], dtype=torch.long),
            "gender": torch.tensor([row["gender"]], dtype=torch.long),
            "age": torch.tensor([row["age"]], dtype=torch.long),
            "occupation": torch.tensor([row["occupation"]], dtype=torch.long),
            "year": torch.tensor([row["year"]], dtype=torch.long),
        }

        label = torch.tensor(row["rating"], dtype=torch.float)

        return sparse_features, label


def collate_fn(batch):
    sparse_features = {
        "user_id": [],
        "movie_id": [],
        "gender": [],
        "age": [],
        "occupation": [],
        "year": [],
    }

    labels = []

    for features, label in batch:
        for key in sparse_features:
            sparse_features[key].extend(features[key].tolist())
        labels.append(label)

    lengths = {
        "user_id": torch.tensor([1] * len(batch), dtype=torch.long),
        "movie_id": torch.tensor([1] * len(batch), dtype=torch.long),
        "gender": torch.tensor([1] * len(batch), dtype=torch.long),
        "age": torch.tensor([1] * len(batch), dtype=torch.long),
        "occupation": torch.tensor([1] * len(batch), dtype=torch.long),
        "year": torch.tensor([1] * len(batch), dtype=torch.long),
    }

    values = {
        "user_id": torch.tensor(sparse_features["user_id"], dtype=torch.long),
        "movie_id": torch.tensor(sparse_features["movie_id"], dtype=torch.long),
        "gender": torch.tensor(sparse_features["gender"], dtype=torch.long),
        "age": torch.tensor(sparse_features["age"], dtype=torch.long),
        "occupation": torch.tensor(sparse_features["occupation"], dtype=torch.long),
        "year": torch.tensor(sparse_features["year"], dtype=torch.long),
    }

    kjt = KeyedJaggedTensor(
        keys=list(values.keys()),
        values=torch.cat([values[k] for k in values.keys()]),
        lengths=torch.cat([lengths[k] for k in lengths.keys()]),
    )

    return kjt, torch.tensor(labels, dtype=torch.float)


class MovieLensModel(nn.Module):
    def __init__(
        self,
        embedding_module: EmbeddingCollection,
        dense_in_features: int,
        dense_arch_layer_sizes: List[int],
        over_arch_layer_sizes: List[int],
    ):
        super().__init__()
        self.embedding_module = embedding_module

        dense_arch_layers = []
        for i in range(len(dense_arch_layer_sizes) - 1):
            dense_arch_layers.append(
                nn.Linear(dense_arch_layer_sizes[i], dense_arch_layer_sizes[i + 1])
            )
            dense_arch_layers.append(nn.ReLU())
        self.dense_arch = nn.Sequential(*dense_arch_layers)

        embedding_dim = embedding_module.embedding_configs()[0].embedding_dim
        for config in embedding_module.embedding_configs():
            assert embedding_dim == config.embedding_dim

        over_arch_layers = []
        if dense_in_features == 0:
            input_dim = embedding_dim
        else:
            input_dim = dense_arch_layer_sizes[-1] + embedding_dim

        over_arch_layers.append(
            nn.Linear(
                input_dim,
                over_arch_layer_sizes[0],
            )
        )
        over_arch_layers.append(nn.ReLU())
        for i in range(len(over_arch_layer_sizes) - 1):
            over_arch_layers.append(
                nn.Linear(over_arch_layer_sizes[i], over_arch_layer_sizes[i + 1])
            )
            over_arch_layers.append(nn.ReLU())
        over_arch_layers.append(nn.Linear(over_arch_layer_sizes[-1], 1))
        self.over_arch = nn.Sequential(*over_arch_layers)

    def forward(self, kjt: KeyedJaggedTensor) -> torch.Tensor:
        embeddings = self.embedding_module(kjt)

        sparse_features = torch.cat(
            [embeddings[k].values() for k in embeddings.keys()], dim=0
        )

        prediction = self.over_arch(sparse_features)
        num_features = len(kjt.keys())
        batch = len(kjt.lengths()) // num_features
        hotness = 1
        # batch_size x hotness(1) x num_feature
        x = prediction.view(hotness * num_features, batch)
        return torch.sum(x.t(), dim=-1)


# use a function warp all the Planner code
def get_planner(device, eb_configs, batch_size):
    DATA_TYPE_NUM_BITS: Dict[DataType, int] = {
        DataType.FP32: 32,
        DataType.FP16: 16,
        DataType.BF16: 16,
    }

    hbm_cap = 80 * 1024 * 1024 * 1024  # H100's HBM bytes per GPU
    ddr_cap = 512 * 1024 * 1024 * 1024  # Assume a Node have 512GB memory
    intra_host_bw = 450e9  # Nvlink bandwidth
    inter_host_bw = 25e9  # NIC bandwidth

    dict_const = {}

    for eb_config in eb_configs:
        # For HVK  embedding table , need to calculate how many bytes of embedding vector store in GPU HBM
        # In this case , we will put all the embedding vector into GPU HBM
        dim = eb_config.embedding_dim
        tmp_type = eb_config.data_type

        embedding_type_bytes = DATA_TYPE_NUM_BITS[tmp_type] / 8
        emb_num_embeddings = eb_config.num_embeddings
        emb_num_embeddings_next_power_of_2 = 2 ** math.ceil(
            math.log2(emb_num_embeddings)
        )  # HKV need embedding vector num is power of 2
        total_hbm_need = embedding_type_bytes * dim * emb_num_embeddings_next_power_of_2

        const = DynamicEmbParameterConstraints(
            sharding_types=[
                ShardingType.ROW_WISE.value,
            ],
            use_dynamicemb=True,  # from here , is all the HKV options , default use_dynamicemb is False , if it is False , it will fallback to raw TorchREC ParameterConstraints
            dynamicemb_options=DynamicEmbTableOptions(
                global_hbm_for_values=total_hbm_need,
                initializer_args=DynamicEmbInitializerArgs(
                    mode=DynamicEmbInitializerMode.NORMAL
                ),
                score_strategy=DynamicEmbScoreStrategy.STEP,
            ),
        )

        dict_const[eb_config.name] = const

    topology = Topology(
        local_world_size=get_local_size(),
        world_size=dist.get_world_size(),
        compute_device=device.type,
        hbm_cap=hbm_cap,
        ddr_cap=ddr_cap,  # For HVK  , if we need to put embedding vector into Host memory , it is important set ddr capacity
        intra_host_bw=intra_host_bw,
        inter_host_bw=inter_host_bw,
    )

    # Same usage of  TorchREC's EmbeddingEnumerator
    enumerator = DynamicEmbeddingEnumerator(
        topology=topology,
        constraints=dict_const,
    )

    # Almost same usage of  TorchREC's EmbeddingShardingPlanner , but we need to input eb_configs, so we can plan every GPU's HKV object.
    return DynamicEmbeddingShardingPlanner(
        eb_configs=eb_configs,
        topology=topology,
        constraints=dict_const,
        batch_size=batch_size,
        enumerator=enumerator,
        storage_reservation=HeuristicalStorageReservation(percentage=0.05),
        debug=True,
    )


def get_dynamicemb_dmp(ebc, args, device):
    eb_configs = ebc.embedding_configs()
    # set optimizer args
    learning_rate = args.lr
    beta1 = 0.9
    beta2 = 0.999
    weight_decay = 0
    eps = 0.001

    # Put args into a optimizer kwargs , which is same usage of TorchREC
    optimizer_kwargs = {
        "optimizer": EmbOptimType.ADAM,
        "learning_rate": learning_rate,
        "beta1": beta1,
        "beta2": beta2,
        "weight_decay": weight_decay,
        "eps": eps,
    }

    fused_params = {}
    fused_params["output_dtype"] = SparseType.FP32
    fused_params.update(optimizer_kwargs)

    qcomm_codecs_registry = (
        get_qcomm_codecs_registry(
            qcomms_config=QCommsConfig(
                # pyre-ignore
                forward_precision=CommType.FP32,
                # pyre-ignore
                backward_precision=CommType.FP32,
            )
        )
        if args.backend == "nccl"
        else None
    )

    # Create a sharder , same usage with TorchREC , but need Use DynamicEmb function, because for index_dedup
    # DynamicEmb overload this process to fit HKV

    sharder = DynamicEmbeddingCollectionSharder(
        qcomm_codecs_registry=qcomm_codecs_registry,
        fused_params=fused_params,
        use_index_dedup=True,
    )

    planner = get_planner(device, eb_configs, args.batch_size)
    # Same usage of TorchREC
    pg_cpu = dist.new_group(backend="gloo")
    plan = planner.collective_plan(ebc, [sharder], pg_cpu)

    data_parallel_wrapper = DefaultDataParallelWrapper(allreduce_comm_precision="fp16")

    # Same usage of TorchREC
    dmp = DistributedModelParallel(
        module=ebc,
        device=device,
        # pyre-ignore
        sharders=[sharder],
        plan=plan,
        data_parallel_wrapper=data_parallel_wrapper,
    )
    return dmp


def create_model(args, device):
    eb_configs = [
        EmbeddingConfig(
            name="user_id",
            embedding_dim=args.embedding_dim,
            num_embeddings=args.num_embeddings,
            feature_names=["user_id"],
        ),
        EmbeddingConfig(
            name="movie_id",
            embedding_dim=args.embedding_dim,
            num_embeddings=args.num_embeddings,
            feature_names=["movie_id"],
        ),
        EmbeddingConfig(
            name="gender",
            embedding_dim=args.embedding_dim,
            num_embeddings=2,
            feature_names=["gender"],
        ),
        EmbeddingConfig(
            name="age",
            embedding_dim=args.embedding_dim,
            num_embeddings=100,
            feature_names=["age"],
        ),
        EmbeddingConfig(
            name="occupation",
            embedding_dim=args.embedding_dim,
            num_embeddings=50,
            feature_names=["occupation"],
        ),
        EmbeddingConfig(
            name="year",
            embedding_dim=args.embedding_dim,
            num_embeddings=2050,
            feature_names=["year"],
        ),
    ]

    ec = EmbeddingCollection(
        tables=eb_configs,
        device=torch.device("meta"),
    )

    mlp_dims = [int(dim) for dim in args.mlp_dims.split(",")]

    model = MovieLensModel(
        embedding_module=ec,
        dense_in_features=0,
        dense_arch_layer_sizes=[1, 1],  # placeholder
        over_arch_layer_sizes=mlp_dims,
    )

    model.embedding_module = get_dynamicemb_dmp(ec, args, device)

    return model


def train(args, global_rank, world_size, device):
    train_dataset = MovieLensDataset(args.data_path, split="train")
    test_dataset = MovieLensDataset(args.data_path, split="test")

    # 使用全局 rank 和 world_size 创建采样器
    train_sampler = DistributedSampler(
        train_dataset, num_replicas=world_size, rank=global_rank, shuffle=True
    )
    test_sampler = DistributedSampler(
        test_dataset, num_replicas=world_size, rank=global_rank, shuffle=False
    )

    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=collate_fn,
        num_workers=4,
        sampler=train_sampler,
    )

    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=collate_fn,
        num_workers=4,
        sampler=test_sampler,
    )

    # 创建模型并传递更新后的设备
    model = create_model(args, device)
    model.to(device)

    optimizer = Adam(model.parameters(), lr=args.lr)
    criterion = nn.MSELoss()

    for epoch in range(args.epochs):
        train_sampler.set_epoch(epoch)
        model.train()
        total_loss = 0

        for batch_idx, (features, labels) in enumerate(train_loader):
            features = features.to(device)
            labels = labels.to(device)

            outputs = model(features)
            loss = criterion(outputs, labels)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()

            if batch_idx % 100 == 0:
                print(
                    f"Epoch {epoch+1}/{args.epochs}, Batch {batch_idx}/{len(train_loader)}, Loss: {loss.item():.4f}"
                )

        avg_loss = total_loss / len(train_loader)
        print(f"Epoch {epoch+1}/{args.epochs}, Average Loss: {avg_loss:.4f}")

        model.eval()
        test_loss = 0
        with torch.no_grad():
            for features, labels in test_loader:
                features = features.to(device)
                labels = labels.to(device)

                outputs = model(features)
                loss = criterion(outputs, labels)
                test_loss += loss.item()

        avg_test_loss = test_loss / len(test_loader)
        print(f"Epoch {epoch+1}/{args.epochs}, Test Loss: {avg_test_loss:.4f}")


def dump(args, global_rank, world_size, device):
    os.makedirs(args.save_dir, exist_ok=True)
    train_dataset = MovieLensDataset(args.data_path, split="train")
    train_sampler = DistributedSampler(
        train_dataset, num_replicas=world_size, rank=global_rank, shuffle=True
    )

    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=collate_fn,
        num_workers=4,
        sampler=train_sampler,
    )

    model = create_model(args, device)
    model.to(device)

    optimizer = Adam(model.parameters(), lr=args.lr)
    criterion = nn.MSELoss()

    for epoch in range(args.epochs):
        train_sampler.set_epoch(epoch)
        model.train()
        total_loss = 0

        for batch_idx, (features, labels) in enumerate(train_loader):
            features = features.to(device)
            labels = labels.to(device)

            outputs = model(features)
            loss = criterion(outputs, labels)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()

            if batch_idx % 100 == 0:
                print(
                    f"Epoch {epoch+1}/{args.epochs}, Batch {batch_idx}/{len(train_loader)}, Loss: {loss.item():.4f}"
                )

        avg_loss = total_loss / len(train_loader)
        print(f"Epoch {epoch+1}/{args.epochs}, Average Loss: {avg_loss:.4f}")

        # 保存模型
        torch.save(
            {
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
            },
            os.path.join(args.save_dir, f"model_epoch_{epoch+1}_rank{global_rank}.pt"),
        )

    # 使用全局 rank 进行 dump
    DynamicEmbDump(os.path.join(args.save_dir, "dynamicemb"), model, optim=True)


def load(args, global_rank, world_size, device):
    os.makedirs(args.save_dir, exist_ok=True)
    test_dataset = MovieLensDataset(args.data_path, split="test")
    test_sampler = DistributedSampler(
        test_dataset, num_replicas=world_size, rank=global_rank, shuffle=False
    )

    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=collate_fn,
        num_workers=4,
        sampler=test_sampler,
    )

    model = create_model(args, device)
    model.to(device)

    optimizer = Adam(model.parameters(), lr=args.lr)
    criterion = nn.MSELoss()

    # 加载模型
    checkpoint = torch.load(
        os.path.join(args.save_dir, f"model_epoch_{args.epochs}_rank{global_rank}.pt"),
        weights_only=True,
    )
    # Must set strict to False, as there is no embedding's weight in model.state_dict()
    model.load_state_dict(checkpoint["model_state_dict"], strict=False)
    optimizer.load_state_dict(checkpoint["optimizer_state_dict"])

    # 所有 rank 从相同的文件加载
    DynamicEmbLoad(os.path.join(args.save_dir, "dynamicemb"), model, optim=True)

    model.eval()
    test_loss = 0
    with torch.no_grad():
        for features, labels in test_loader:
            features = features.to(device)
            labels = labels.to(device)

            outputs = model(features)
            loss = criterion(outputs, labels)
            test_loss += loss.item()

    avg_test_loss = test_loss / len(test_loader)
    print(f"Test Loss: {avg_test_loss:.4f}")

    # 使用设备 ID
    dist.barrier(device_ids=[args.local_rank])
    if global_rank == 0:
        shutil.rmtree(args.save_dir)
    dist.barrier(device_ids=[args.local_rank])


def inc_dump(args, global_rank, world_size, device):
    os.makedirs(args.save_dir, exist_ok=True)
    train_dataset = MovieLensDataset(args.data_path, split="train")
    train_sampler = DistributedSampler(
        train_dataset, num_replicas=world_size, rank=global_rank, shuffle=True
    )

    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=collate_fn,
        num_workers=4,
        sampler=train_sampler,
    )

    model = create_model(args, device)
    model.to(device)

    optimizer = Adam(model.parameters(), lr=args.lr)
    criterion = nn.MSELoss()

    undumped_score = get_score(model)

    for epoch in range(args.epochs):
        train_sampler.set_epoch(epoch)
        model.train()
        total_loss = 0

        for batch_idx, (features, labels) in enumerate(train_loader):
            features = features.to(device)
            labels = labels.to(device)

            outputs = model(features)
            loss = criterion(outputs, labels)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()

            if batch_idx % 100 == 0:
                # reset undumped_score here.
                ret_tensors, undumped_score = incremental_dump(model, undumped_score)
                dump_number = 0
                for module_path, named_tensors in ret_tensors.items():
                    for table_name, tensors in named_tensors.items():
                        dump_number += tensors[0].size(0)
                print(
                    f"Epoch {epoch+1}/{args.epochs}, Batch {batch_idx}/{len(train_loader)}, Loss: {loss.item():.4f}, dump number: {dump_number}"
                )

        avg_loss = total_loss / len(train_loader)
        print(f"Epoch {epoch+1}/{args.epochs}, Average Loss: {avg_loss:.4f}")


def main():
    args = parse_args()

    # 初始化分布式环境
    global_rank, world_size, device = init_distributed(args)

    # 设置打印带有 rank 信息的函数
    setup_rank_print(global_rank)

    # 设置随机种子
    torch.cuda.manual_seed(args.seed)
    np.random.seed(args.seed)

    # 只在全局 rank 0 上下载数据
    if args.local_rank == 0:
        download_movielens(args.data_path)

    # 确保所有进程等待数据下载完成
    dist.barrier()

    # 调用相应的函数
    if args.train:
        train(args, global_rank, world_size, device)
    if args.dump:
        dump(args, global_rank, world_size, device)
    if args.load:
        load(args, global_rank, world_size, device)
    if args.incremental_dump:
        inc_dump(args, global_rank, world_size, device)

    # 销毁进程组
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
