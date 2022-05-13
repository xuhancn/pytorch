import io
from typing import Any, Dict, List, Tuple, Optional, Union

import torch
import torch.distributed as dist

from torch import Tensor
from torch.distributed._shard.sharded_tensor import (
    ShardedTensor,
)

from .metadata import (
    Metadata,
    BytesWriteRequest,
    TensorWriteRequest,
)
from .resharding import (
    _prepare_sharded_tensor_write,
    _prepare_tensor_write,
    _prepare_bytes_write
)

from .storage import StorageWriter

# -------------- private functions --------------

def _prepare(
    state_dict: Dict[str, Any]
) -> Tuple[Metadata, List[BytesWriteRequest], List[TensorWriteRequest]]:
    """
    Build the serialization plan for a given state_dict

    Args:
        state_dict: The instance to plan for.

    Returns:
        A tuple with the following values:

        metadata: Metadata
        The storage metadata describing Tensor and ShardedTensors
        instances found in `state_dict`. See `Metadata` for the schema.

        size_for_storage_keys: Dict[str, int]
            Key is the storage key name, value is the associated size
            It can used to pre allocate the storage for parallel and non sequential writes.

        bytes_write_requests: List[BytesWriteRequest]
            List of ByteIO write requests that should be performed by the writer.

        tensor_write_requests: List[TensorWriteRequest]
            List of Tensor write requests that should be performed by the writer.

    """
    metadata = Metadata(state_dict_metadata={})
    tensor_write_requests: List[TensorWriteRequest] = []
    bytes_write_requests: List[BytesWriteRequest] = []
    storage_key_to_fqn: Dict[str, str] = dict()
    # The assumption is that all non ShardedTensor items are replicated
    #   and we can save them from rank 0.
    write_replicated_data = not (dist.is_initialized() and dist.get_rank() != 0)

    for fqn, obj in state_dict.items():
        if isinstance(obj, ShardedTensor):
            st_write_reqs, st_md = _prepare_sharded_tensor_write(obj, fqn, storage_key_to_fqn)
            tensor_write_requests += st_write_reqs
            metadata.state_dict_metadata[fqn] = st_md
        elif isinstance(obj, Tensor):
            write_reqs, tensor_md = _prepare_tensor_write(obj, fqn, storage_key_to_fqn)
            if write_replicated_data:
                tensor_write_requests += write_reqs
            metadata.state_dict_metadata[fqn] = tensor_md
        else:
            bytes_io = io.BytesIO()
            # This produces incomplete MD for rank > 0 since we won't populate bytes_io.
            # This is ok since only rank == 0 uses this data
            if write_replicated_data:
                torch.save(obj, bytes_io)
            byte_write_reqs, bytes_md = _prepare_bytes_write(bytes_io, fqn, storage_key_to_fqn)
            if write_replicated_data:
                bytes_write_requests += byte_write_reqs
            metadata.state_dict_metadata[fqn] = bytes_md

    return (metadata, bytes_write_requests, tensor_write_requests)


def save_state_dict(
    state_dict: Dict[str, Any],
    storage_writer: StorageWriter,
    process_group: Optional[dist.ProcessGroup] = None
) -> None:
    """
    Save a distributed model in SPMD style.

    This function is different from ``torch.save()`` as it handles
    ``ShardedTensor`` by having each rank only save their local shards.

    To produce a state_dict with ShardedTensor instances you must call
    ``_register_state_dict_hook`` on the top module with value
    `torch.distributed._shard.sharded_tensor.state_dict_hook` prior to
    calling `state_dict()` on the top module.

    There is no guarantees of Backwards Compatibility across PyTorch versions
    for saved state_dicts.

    If using the `process_group` argument, make sure that only its ranks
    call `save_state_dict` and that all data in state_dict belong to it.

    Args:
        state_dict (Dict[str, Any]) : A state_dict
        storage_writer (StorageWriter): Instance of StorageWrite use to perform writes.
        process_group (ProcessGroup): ProcessGroup to be used for cross-rank synchronization

    Example:
        >>> my_model = MyModule()
        >>> # We must call this function prior to state_dict()
        >>> my_model._register_state_dict_hook(state_dict_hook)

        >>> model_state_dict = my_model.state_dict()

        >>> fs_storage_writer = torch.distributed._shard.checkpoint.FileSystemWriter("/checkpoint/1")
        >>> torch.distributed._shard.checkpoint.save_state_dict(
        >>>     state_dict=model_state_dict,
        >>>     storage_writer=fs_stroage_writer,
        >>> )
    """
    (
        metadata,
        bytes_write_requests,
        tensor_write_requests,
    ) = _prepare(state_dict)

    is_rank0 = not dist.is_initialized() or dist.get_rank(process_group) == 0
    if is_rank0:
        storage_writer.prepare()

    # Writing can only start once prepare has finished
    if dist.is_initialized():
        dist.barrier(process_group)

    combined_writes: List[Union[TensorWriteRequest, BytesWriteRequest]] = []
    combined_writes.extend(tensor_write_requests)
    combined_writes.extend(bytes_write_requests)

    storage_writer.prepare_storage(combined_writes)
    bytes_futures = storage_writer.write_bytes(bytes_write_requests)
    tensor_futures = storage_writer.write_tensors(tensor_write_requests)
    torch.futures.wait_all([bytes_futures, tensor_futures])

    if is_rank0:
        storage_writer.write_metadata(metadata=metadata)
        storage_writer.finish()
    # barrier at the end that ensures all ranks can see the checkpoint
    if dist.is_initialized():
        dist.barrier(process_group)
