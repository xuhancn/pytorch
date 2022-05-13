//  Copyright © 2022 Apple Inc.

#include <ATen/EmptyTensor.h>
#include <ATen/ATen.h>
#include <ATen/Tensor.h>
#include <ATen/Utils.h>
#include <torch/library.h>
#include <ATen/native/Resize.h>
#include <ATen/native/mps/Copy.h>
namespace at { namespace detail {
TensorBase empty_mps(
    IntArrayRef size,
    c10::optional<ScalarType> dtype_opt,
    c10::optional<Layout> layout_opt,
    c10::optional<Device> device_opt,
    c10::optional<bool> pin_memory_opt,
    c10::optional<c10::MemoryFormat> memory_format_opt) {

  auto device = device_or_default(device_opt);
  TORCH_INTERNAL_ASSERT_DEBUG_ONLY(device.type() == DeviceType::MPS);

  TORCH_CHECK_NOT_IMPLEMENTED(
      layout_or_default(layout_opt) == Layout::Strided,
      "strided meta tensors not supported yet");
  check_size_nonnegative(size);

  auto* allocator = at::mps::GetMPSAllocator();
  int64_t nelements = c10::multiply_integers(size);
  auto dtype = dtype_or_default(dtype_opt);
  auto dtype_meta = scalarTypeToTypeMeta(dtype);
  int64_t size_bytes = nelements * dtype_meta.itemsize();
  auto storage_impl = c10::make_intrusive<StorageImpl>(
      c10::StorageImpl::use_byte_size_t(),
      size_bytes,
      allocator->allocate(size_bytes),
      allocator,
      /*resizeable=*/true);

  auto tensor =
      detail::make_tensor<TensorImpl>(storage_impl, DispatchKey::MPS, dtype_meta);
  // Default TensorImpl has size [0]
  if (size.size() != 1 || size[0] != 0) {
    tensor.unsafeGetTensorImpl()->set_sizes_contiguous(size);
  }

  auto memory_format = memory_format_opt.value_or(MemoryFormat::Contiguous);
  tensor.unsafeGetTensorImpl()->empty_tensor_restride(memory_format);
  return tensor;

}

TensorBase empty_mps(
    IntArrayRef size, const TensorOptions &options) {
  return at::detail::empty_mps(
      size,
      optTypeMetaToScalarType(options.dtype_opt()),
      options.layout_opt(),
      options.device_opt(),
      options.pinned_memory_opt(),
      options.memory_format_opt());
}

TensorBase empty_strided_mps(
    IntArrayRef size,
    IntArrayRef stride,
    ScalarType dtype,
    c10::optional<Device> device_opt) {
  auto device = device_or_default(device_opt);
  TORCH_INTERNAL_ASSERT(device.is_mps());
  const DeviceGuard device_guard(device);
  auto* allocator = at::mps::GetMPSAllocator();
  constexpr c10::DispatchKeySet mps_dks(c10::DispatchKey::MPS);
  return at::detail::empty_strided_generic(
      size, stride, allocator, mps_dks, dtype);
}

TensorBase empty_strided_mps(
    IntArrayRef size,
    IntArrayRef stride,
    const TensorOptions &options) {
  return at::native::empty_strided_mps(
      size,
      stride,
      optTypeMetaToScalarType(options.dtype_opt()),
      options.layout_opt(),
      options.device_opt(),
      options.pinned_memory_opt());
}

} // namespace detail
} // namespace at
