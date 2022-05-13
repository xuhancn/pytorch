//  Copyright © 2022 Apple Inc.

#include <ATen/native/mps/OperationUtils.h>

namespace at {
namespace native {
namespace mps {

uint64_t MPSGeneratorImpl::seed() {
  auto random = c10::detail::getNonDeterministicRandom(true);
  this->set_current_seed(random);
  return random;
}
uint64_t MPSGeneratorImpl::current_seed() const {
  return seed_;
}

void MPSGeneratorImpl::set_current_seed(uint64_t seed) {
  seed_ = seed;
}

MPSGeneratorImpl::MPSGeneratorImpl(DeviceIndex device_index)
  : c10::GeneratorImpl{Device(DeviceType::MPS, device_index),
              DispatchKeySet(c10::DispatchKey::MPS)} {
}

const Generator& getDefaultMPSGenerator() {
  auto gen = make_generator<MPSGeneratorImpl>(0);
  gen.seed();
  return gen;
}
DeviceType MPSGeneratorImpl::device_type() {
  return DeviceType::MPS;
}
c10::intrusive_ptr<c10::TensorImpl> MPSGeneratorImpl::get_state() const {
  static const size_t seed_size = sizeof(uint64_t);
  static const size_t offset_size = sizeof(int64_t);
  static const size_t total_size = seed_size + offset_size;

  auto state_tensor = at::detail::empty_cpu({(int64_t)total_size}, ScalarType::Byte, c10::nullopt, c10::nullopt, c10::nullopt, c10::nullopt);
  auto rng_state = state_tensor.data_ptr<uint8_t>();

  return state_tensor.getIntrusivePtr();
}

void MPSGeneratorImpl::set_state(const c10::TensorImpl& new_state) {
  static const size_t seed_size = sizeof(uint64_t);
  static const size_t offset_size = sizeof(int64_t);
  static const size_t total_size = seed_size + offset_size;

  detail::check_rng_state(new_state);

  auto new_state_size = new_state.numel();

  uint64_t input_seed;
  auto new_rng_state = new_state.data<uint8_t>();
  memcpy(&input_seed, new_rng_state, seed_size);
  this->set_current_seed(input_seed);
}

MPSGeneratorImpl* MPSGeneratorImpl::clone_impl() const {
  auto gen = new MPSGeneratorImpl(0);
  gen->set_current_seed(this->seed_);
  return gen;
}

std::string getStridedKey(const Tensor& self, const IntArrayRef sz,
                          const IntArrayRef strides, int64_t offset) {
  // TODO: move storage_offset to a PlaceholderTensor and strides to a
  // tensor too, to avoid too many cache entries.
  return std::to_string((uintptr_t)self.storage().data()) +
              ":" + mps::getArrayRefString(sz) +
              ":" + mps::getArrayRefString(strides) +
              ":" + std::to_string(offset);
}

void runMPSGraph(
    MPSStream* mpsStream,
    MPSGraph* mpsGraph,
    NSDictionary* feeds,
    NSDictionary* results) {

  dispatch_sync(mpsStream->queue(), ^() {
    @autoreleasepool {
      mpsStream->commit(true);
      id<MTLCommandQueue> commandQueue = mpsStream->commandQueue();
      MPSGraphExecutionDescriptor *executionDescriptor = [[MPSGraphExecutionDescriptor new] autorelease];

      executionDescriptor.completionHandler = ^(NSDictionary<MPSGraphTensor *,
                                                MPSGraphTensorData *> * resultsDictionary,
                                                NSError * _Nullable error) {
      };

      [mpsGraph runAsyncWithMTLCommandQueue:commandQueue
                                feeds:feeds
                     targetOperations:nil
                    resultsDictionary:results
                  executionDescriptor:executionDescriptor];

    }
  });
}

MPSDataType getMPSDataType(ScalarType scalar_type) {
  switch (scalar_type) {
    case ScalarType::Float:
      return MPSDataTypeFloat32;
    case ScalarType::Half:
      return MPSDataTypeFloat16;
    case ScalarType::Int:
      return MPSDataTypeInt32;
    case ScalarType::Long:
      return MPSDataTypeInt64;
    case ScalarType::Short:
      return MPSDataTypeInt16;
    case ScalarType::Byte:
      return MPSDataTypeInt8;
    case ScalarType::Bool:
      return MPSDataTypeBool;
    default:
      TORCH_CHECK_TYPE(false, "Unsupported data type '", scalar_type, "' on MPS backend");
  }
}

MPSDataType getMPSScalarType(ScalarType scalar_type) {
  switch (scalar_type) {
    // Intentional fall-through as we can support Scalars with Double type
    case ScalarType::Double:
    case ScalarType::Float:
      return MPSDataTypeFloat32;
    case ScalarType::Half:
      return MPSDataTypeFloat16;
    case ScalarType::Int:
      return MPSDataTypeInt32;
    case ScalarType::Long:
      return MPSDataTypeInt64;
    case ScalarType::Short:
      return MPSDataTypeInt16;
    case ScalarType::Byte:
      return MPSDataTypeInt8;
    case ScalarType::Bool:
      return MPSDataTypeBool;
    default:
      TORCH_INTERNAL_ASSERT(false, "Unsupported data type '", scalar_type, "' on MPS backend");
  }
}

std::string getMPSTypeString(ScalarType scalar_type) {
  switch (scalar_type) {
    case ScalarType::Double:
    case ScalarType::Float:
      return "MPSDataTypeFloat32";
    case ScalarType::Half:
      return "MPSDataTypeFloat16";
    case ScalarType::Int:
      return "MPSDataTypeInt32";
    case ScalarType::Long:
      return "MPSDataTypeInt64";
    case ScalarType::Short:
      return "MPSDataTypeInt16";
    case ScalarType::Byte:
      return "MPSDataTypeInt8";
    case ScalarType::Bool:
      return "MPSDataTypeBool";
    default:
      return "Undefined";
  }
}

std::string getMPSShapeString(MPSShape* shape) {
    std::string str;
    for(NSNumber *elem in shape) {
        str += std::to_string(elem.unsignedLongValue) + ",";
    }
    return str;
}

std::string getArrayRefString(const IntArrayRef s) {
  std::stringstream ss;
  std::copy(s.begin(), s.end(), std::ostream_iterator<int>(ss, ","));
  return ss.str();
}

std::string getTensorsStringKey(const TensorList& tensors) {
    std::string str;
    // The key format per tensor would look like ":MPSDataTypeFloat32[1,1,1,10]:"
    for (const Tensor& tensor: tensors) {
      str += ":";
      if (tensor.defined()) {
        str += getMPSTypeString(tensor.scalar_type()) + "[";
        // if tensor is a scalar
        if (tensor.dim() == 0) {
          str += std::to_string(getMPSScalarValue(tensor));
        } else {
          const NSString* ns_shape_key = [[getMPSShape(tensor) valueForKey:@"description"] componentsJoinedByString:@","];
          str += std::string(ns_shape_key.UTF8String);
        }
        str += "]";
      } else {
        str += "Undefined";
      }
    }
    return str;
}

double getMPSScalarValue(const Tensor& t) {
  assert (t.dim() == 0);  // only applicable for scalar types
  auto other_value = t.item();
  return other_value.to<double>();
}

MPSShape* getMPSShape(const Tensor& t) {
  const int sz = t.dim();
  const int sz_ = (sz > 0) ? sz : 1;

  NSNumber* numbers[sz_];

  for (int i = 0; i < sz_; i++)
  {
    NSInteger sz_i = (i < sz) ? t.size(i) : 1;

    NSNumber* number = [NSNumber numberWithInt:sz_i];
    numbers[i] = number;
  }
  return [NSArray arrayWithObjects:numbers count:sz_];
}

MPSShape* getMPSShape(c10::MaybeOwned<Tensor> t) {
  const Tensor& t_ = *t;
  return getMPSShape(t_);
}

MPSShape* getMPSShape(IntArrayRef sizes) {
  const int sz = sizes.size();
  const int sz_ = (sz > 0) ? sz : 1;

  NSNumber* numbers[sz_];

  for (int i = 0; i < sz_; i++)
  {
    NSInteger sz_i = (i < sz) ? sizes[i] : 1;

    NSNumber* number = [NSNumber numberWithInt:sz_i];
    numbers[i] = number;
  }
  return [NSArray arrayWithObjects:numbers count:sz_];
}

void printTensorNDArray(const Tensor& t) {
  if (!t.is_mps()) return;
  if(t.numel() == 0)
  {
      std::cout << "Empty tensor" << std::endl;
      return;
  }
  // Get shape and data type
  auto selfShape = getMPSShape(t);
  auto selfDType = getMPSDataType(t.scalar_type());

  // Initialize data
  id<MTLBuffer> selfBuf = __builtin_bit_cast(id<MTLBuffer>, t.storage().data());
  MPSGraphTensorData* tdata = [[MPSGraphTensorData alloc] initWithMTLBuffer:selfBuf
                                                            shape:selfShape
                                                         dataType:selfDType];
  [tdata printNDArray];
}

id<MTLBuffer> gatherViewTensor(const at::Tensor& src, id<MTLBuffer> sourceBuffer) {
  assert (!src.is_contiguous());
  id<MTLDevice> device = MPSDevice::getInstance()->device();
  MPSStream* stream = getCurrentMPSStream();
  @autoreleasepool {
    struct CachedGraph : public MPSCachedGraph
    {
      CachedGraph(MPSGraph *graph) : MPSCachedGraph(graph) {}
      MPSGraphTensor* inputTensor_ = nil;
      MPSGraphTensor* outputTensor_ = nil;
      IntArrayRef size_;
      IntArrayRef stride_;
      int64_t storage_offset_;
    };

    MPSGraphCache* cache_ = MPSGraphCache::getInstance();
    string key = getStridedKey(src, src.sizes(), src.strides(), src.storage_offset());
    CachedGraph* cachedGraph = static_cast<CachedGraph *>(cache_->LookUp(key));
    if (cachedGraph) {
      @autoreleasepool {
        MPSGraphTensor* inputTensor = cachedGraph->inputTensor_;
        auto output = at::native::empty_mps(
                        src.sizes(),
                        src.scalar_type(),
                        c10::nullopt,
                        kMPS,
                        c10::nullopt,
                        c10::nullopt);
        MPSGraphTensorData* inputTensorData = [[MPSGraphTensorData alloc] initWithMTLBuffer: sourceBuffer
                                                                            shape: [inputTensor shape]
                                                                            dataType: [inputTensor dataType]];
        id<MTLBuffer> resultBuffer = __builtin_bit_cast(id<MTLBuffer>, output.storage().data());
        MPSGraphTensorData* outputTensorData = [[MPSGraphTensorData alloc] initWithMTLBuffer: resultBuffer
                                                                            shape: getMPSShape(src.sizes())
                                                                            dataType: getMPSDataType(src.scalar_type())];
        NSDictionary<MPSGraphTensor*, MPSGraphTensorData*>* feeds = @{
          inputTensor : inputTensorData
        };

        NSDictionary<MPSGraphTensor*, MPSGraphTensorData*>* results = @{
          cachedGraph->outputTensor_ : outputTensorData
        };

        runMPSGraph(stream, cachedGraph->graph(), feeds, results);
#if _DEBUG
        NSLog(@"%@", [cachedGraph->graph() debugDescription]);
        TORCH_WARN("We have a non-contiguous tensor in copy_from_mps with key ", key);

        //// Update the Blit sourceBuffer to the result of this operation
        printTensorNDArray(output);
#endif
        return resultBuffer;
      }
    } else {
      TORCH_WARN("We have a non-contiguous tensor in copy_from_mps with no cached graph with key ", key);
    }
  }
  return nil;
}



Placeholder::Placeholder(MPSGraphTensor* mpsGraphTensor, const Tensor& self, MPSShape *mpsShape)
{
  TORCH_CHECK(self.is_mps(), "Placeholder storage has not been allocated on MPS device!");
  // extract the pointer to MTLBuffer from the Tensor's storage
  id<MTLBuffer> selfBuf = __builtin_bit_cast(id<MTLBuffer>, self.storage().data());
  const size_t buf_size = [selfBuf length];

  // tensor.numel() could be zero, but tensor is valid as long as the buffer size is non-zero.
  // if buf_size is zero in here, it's not a user error. It could be a missing check for
  // tensor.numel() == 0 in our internal implementations of ops.
  TORCH_INTERNAL_ASSERT(buf_size > 0, "Placeholder tensor is empty!");

  TORCH_CHECK(self.storage().nbytes() <= buf_size, "Placeholder buffer size (", buf_size,
      ") is not large enough to contain the Tensor storage of size ", self.storage().nbytes());

  const MPSDataType mpsDataType = getMPSDataType(self.scalar_type());
  if (!mpsShape)
    mpsShape = getMPSShape(self);

  _value = [[MPSGraphTensorData alloc] initWithMTLBuffer:selfBuf
                                                   shape:mpsShape
                                                dataType:mpsDataType];
  TORCH_INTERNAL_ASSERT(_value);
  _placeholder = mpsGraphTensor;
}

MPSGraphTensorData *getMPSGraphTensorData(MPSGraph* mpsGraph,
                                          MPSStream* mpsStream,
                                          const Tensor& tensor) {
  auto mpsShape = getMPSShape(tensor);
  auto dataType = getMPSDataType(tensor.scalar_type());

  MPSGraphTensorData *result = nil;
  if (tensor.numel() > 0) {
    id<MTLBuffer> buf = __builtin_bit_cast(id<MTLBuffer>, tensor.storage().data());
    result = [[[MPSGraphTensorData alloc] initWithMTLBuffer:buf
                                                    shape:mpsShape
                                                 dataType:dataType]
                                                 autorelease];
  } else {
    // create empty NDArray
    MPSNDArrayDescriptor *desc = [MPSNDArrayDescriptor descriptorWithDataType:dataType
                                                                        shape:mpsShape];
    MPSNDArray *emptyArray = [[[MPSNDArray alloc]
                              initWithDevice:mpsStream->device() descriptor:desc] autorelease];
    result = [[[MPSGraphTensorData alloc] initWithMPSNDArray:emptyArray] autorelease];
  }
  assert(result);
  return result;
}

void resize_tensor(Tensor* output) {
  output->resize_(output->sizes());
}

MPSGraph* make_mps_graph() {
  MPSGraph* mpsGraph = [[MPSGraph new] autorelease];
  mpsGraph.options = MPSGraphOptionsNone;
  return mpsGraph;
}

MPSGraphTensor* mpsGraphConstantFloatPlaceHolder(MPSGraph *mpsGraph, const double value, MPSShape* mpsShape) {
  // "value" is always double, so is the Placeholder's type (we only support Float32).
  return [mpsGraph constantWithScalar:value
                                shape:mpsShape
                             dataType:MPSDataTypeFloat32];
}

MPSGraphTensor* mpsGraphUnrankedPlaceHolder(MPSGraph *mpsGraph, MPSDataType dataType) {
  return [mpsGraph placeholderWithShape:nil
                               dataType:dataType
                                   name:nil];
}

MPSGraphTensor* mpsGraphRankedPlaceHolder(MPSGraph *mpsGraph, MPSDataType dataType, MPSShape* mpsShape) {
  return [mpsGraph placeholderWithShape:mpsShape
                               dataType:dataType
                                   name:nil];
}

MPSGraphTensor* mpsGraphRankedPlaceHolder(MPSGraph *mpsGraph, const Tensor& tensor) {
    return [mpsGraph placeholderWithShape:getMPSShape(tensor)
                                 dataType:getMPSDataType(tensor.scalar_type())
                                     name:nil];
}


string get_mem_format_string(c10::MemoryFormat memory_format) {
  string mem_format_key;
  switch(memory_format) {
    case at::MemoryFormat::Contiguous:
      mem_format_key = "Contiguous";
      break;
    case at::MemoryFormat::ChannelsLast:
      mem_format_key = "ChannelsLast";
      break;
    default:
      assert(0 && "Invalid memory format\n");
  }

  return mem_format_key;
}

MPSGraphCache* MPSGraphCache::_instance_cache = nullptr;

} // namespace mps
} // namespace native
} // namespace at
