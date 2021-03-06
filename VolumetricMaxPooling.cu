#include "TH.h"
#include "THCDeviceTensor.cuh"
#include "THCDeviceTensorUtils.cuh"
#include "THCDeviceUtils.cuh"

#include "utils.h"

__global__ void cuda_VolumetricMaxPooling_updateOutput(
  THCDeviceTensor<float, 4> input, THCDeviceTensor<float, 4> indices,
  THCDeviceTensor<float, 4> output,
  int kT, int kH, int kW, int dT, int dH, int dW) {
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = blockIdx.z % output.getSize(1); // output frame/time
  int slice   = blockIdx.z / output.getSize(1); // output slice/feature

  if (oRow < output.getSize(2) && oColumn < output.getSize(3)) {
    int iColumn = oColumn * dW;
    int iRow    = oRow    * dH;
    int iFrame  = oFrame  * dT;

    int maxColumn;
    int maxRow;
    int maxFrame;

    float max = -THInf;

    float *in = &input[slice][iFrame][iRow][iColumn];
    int frameOffset = 0;
    for (int frame = 0; frame < kT; ++frame) {
      int rowOffset = frameOffset;
      for (int row = 0; row < kH; ++row) {
        int columnOffset = rowOffset;
        for (int column = 0; column < kW; ++column) {
          float val = in[columnOffset];
          if (max < val) {
            max = val;
            maxColumn = column;
            maxRow    = row;
            maxFrame  = frame;
          }
          ++columnOffset;
        }
        rowOffset += input.getSize(3);
      }
      frameOffset += input.getSize(2) * input.getSize(3);
    }

    output[slice][oFrame][oRow][oColumn] = max;
    float *idx = &indices[slice][oFrame][oRow][oColumn];
    ((unsigned char*)(idx))[0] = maxFrame;
    ((unsigned char*)(idx))[1] = maxRow;
    ((unsigned char*)(idx))[2] = maxColumn;
    ((unsigned char*)(idx))[3] = 0;
  }
}

template <int KERNEL_WIDTH>
__global__ void cuda_VolumetricMaxPooling_updateOutput(
  THCDeviceTensor<float, 4> input, THCDeviceTensor<float, 4> indices,
  THCDeviceTensor<float, 4> output,
  int kT, int kH, int dT, int dH, int dW) {
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = blockIdx.z % output.getSize(1); // output frame/time
  int slice   = blockIdx.z / output.getSize(1); // output slice/feature

  if (oRow < output.getSize(2) && oColumn < output.getSize(3)) {
    int iColumn = oColumn * dW;
    int iRow    = oRow    * dH;
    int iFrame  = oFrame  * dT;

    int maxColumn;
    int maxRow;
    int maxFrame;

    float max = -THInf;

    float *in = &input[slice][iFrame][iRow][iColumn];
    int frameOffset = 0;
    for (int frame = 0; frame < kT; ++frame) {
      int rowOffset = frameOffset;
      for (int row = 0; row < kH; ++row) {
        int columnOffset = rowOffset;
        for (int column = 0; column < KERNEL_WIDTH; ++column) {
          float val = in[columnOffset];
          if (max < val) {
            max = val;
            maxColumn = column;
            maxRow    = row;
            maxFrame  = frame;
          }
          ++columnOffset;
        }
        rowOffset += input.getSize(3);
      }
      frameOffset += input.getSize(2) * input.getSize(3);
    }

    output[slice][oFrame][oRow][oColumn] = max;
    float *idx = &indices[slice][oFrame][oRow][oColumn];
    ((unsigned char*)(idx))[0] = maxFrame;
    ((unsigned char*)(idx))[1] = maxRow;
    ((unsigned char*)(idx))[2] = maxColumn;
    ((unsigned char*)(idx))[3] = 0;
  }
}

#define UPDATE_OUTPUT_KERNEL_WIDTH(KW) case KW:                         \
  cuda_VolumetricMaxPooling_updateOutput<KW><<<grid, block,             \
                                0, THCState_getCurrentStream(state)>>>( \
    cudaInput, cudaIndices, cudaOutput, kT, kH, dT, dH, dW);            \
  break


static int cunn_VolumetricMaxPooling_updateOutput(lua_State *L) {
  // State
  THCState *state = getCutorchState(L);
  // Input
  THCudaTensor* input = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 2, "torch.CudaTensor"));
  // Indices
  THCudaTensor* indices = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "indices", "torch.CudaTensor"));

  // Params:
  int dT = luaT_getfieldcheckint(L, 1, "dT");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int kT = luaT_getfieldcheckint(L, 1, "kT");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int kW = luaT_getfieldcheckint(L, 1, "kW");

  THCudaTensor* output = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor"));

  int batchSize;
  int inputSlices;
  int inputTime;
  int inputHeight;
  int inputWidth;

  THAssert(THCudaTensor_checkGPU(state, 3, input, indices, output));

  if (THCudaTensor_nDimension(state, input) == 4) {
    luaL_argcheck(L,
                  THCudaTensor_size(state, input, 1) >= kT &&
                  THCudaTensor_size(state, input, 2) >= kH &&
                  THCudaTensor_size(state, input, 3) >= kW, 2,
                  "input image smaller than kernel size");
    /* sizes */
    batchSize   = 1;
    inputSlices = THCudaTensor_size(state, input, 0);
    inputTime   = THCudaTensor_size(state, input, 1);
    inputHeight = THCudaTensor_size(state, input, 2);
    inputWidth  = THCudaTensor_size(state, input, 3);
  } else if (THCudaTensor_nDimension(state, input) == 5) {
    luaL_argcheck(L,
                  THCudaTensor_size(state, input, 4) >= kW &&
                  THCudaTensor_size(state, input, 3) >= kH &&
                  THCudaTensor_size(state, input, 2) >= kT, 2,
                  "input image smaller than kernel size");
    /* sizes */
    batchSize   = THCudaTensor_size(state, input, 0);
    inputSlices = THCudaTensor_size(state, input, 1);
    inputTime   = THCudaTensor_size(state, input, 2);
    inputHeight = THCudaTensor_size(state, input, 3);
    inputWidth  = THCudaTensor_size(state, input, 4);
  } else {
    luaL_argcheck(L, 0, 2, "4D or 5D tensor expected");
  }

  int outputTime   = (inputTime   - kT) / dT + 1;
  int outputHeight = (inputHeight - kH) / dH + 1;
  int outputWidth  = (inputWidth  - kW) / dW + 1;

  if (input->nDimension == 4) { /* 4D */
    /* resize output */
    THCudaTensor_resize4d(state, output, inputSlices,
                          outputTime, outputHeight, outputWidth);
    /* indices pack ti,i,j locations for each output point as uchar into
     each float of the tensor */
    THCudaTensor_resize4d(state, indices, inputSlices,
                          outputTime, outputHeight, outputWidth);
  } else { /* 5D */
    THCudaTensor_resize5d(state, output, batchSize, inputSlices,
                          outputTime, outputHeight, outputWidth);
    // Index tensor packs index offsets as uchars into floats
    THCudaTensor_resize5d(state, indices, batchSize, inputSlices,
                          outputTime, outputHeight, outputWidth);
  }

  input = THCudaTensor_newContiguous(state, input);

  // Collapse batch and feature dimensions
  THCDeviceTensor<float, 4> cudaInput;
  THCDeviceTensor<float, 4> cudaOutput;
  if (THCudaTensor_nDimension(state, input) == 4) {
    cudaInput  = toDeviceTensor<float, 4>(state, input);
    cudaOutput = toDeviceTensor<float, 4>(state, output);
  } else {
    cudaInput = toDeviceTensor<float, 5>(state, input).downcastOuter<4>();
    cudaOutput =
      toDeviceTensor<float, 5>(state, output).downcastOuter<4>();
  }

  THLongStorage *indicesSize = THLongStorage_newWithSize(4);
  long indicesSizeRaw[4] = {batchSize * inputSlices,
                            outputTime, outputHeight, outputWidth};
  THLongStorage_rawCopy(indicesSize, indicesSizeRaw);
  THCudaTensor *indices1 = THCudaTensor_newWithStorage(
    state, THCudaTensor_storage(state, indices),
    THCudaTensor_storageOffset(state, indices), indicesSize, NULL);
  THLongStorage_free(indicesSize);
  THCDeviceTensor<float, 4> cudaIndices =
    toDeviceTensor<float, 4>(state, indices1);

  dim3 block(32, 8);
  dim3 grid(THCCeilDiv(outputWidth, static_cast<int>(block.x)),
            THCCeilDiv(outputHeight, static_cast<int>(block.y)),
            outputTime * inputSlices * batchSize);

  switch (kW) {
    UPDATE_OUTPUT_KERNEL_WIDTH(1);
    UPDATE_OUTPUT_KERNEL_WIDTH(2);
    UPDATE_OUTPUT_KERNEL_WIDTH(3);
    UPDATE_OUTPUT_KERNEL_WIDTH(4);
    UPDATE_OUTPUT_KERNEL_WIDTH(5);
    UPDATE_OUTPUT_KERNEL_WIDTH(6);
    UPDATE_OUTPUT_KERNEL_WIDTH(7);
    default:
      cuda_VolumetricMaxPooling_updateOutput<<<grid, block,
        0, THCState_getCurrentStream(state)>>>(
        cudaInput, cudaIndices, cudaOutput, kT, kH, kW, dT, dH, dW);
  }

  THCudaTensor_free(state, input);
  THCudaTensor_free(state, indices1);

  return 1;
}

#undef UPDATE_OUTPUT_KERNEL_WIDTH

__global__ void cuda_VolumetricMaxPooling_updateGradInput(
  THCDeviceTensor<float, 4> gradOutput, THCDeviceTensor<float, 4> indices,
  THCDeviceTensor<float, 4> gradInput, int dT, int dH, int dW) {
  int oColumn = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow    = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame  = blockIdx.z % gradOutput.getSize(1); // output frame/time
  int slice   = blockIdx.z / gradOutput.getSize(1); // output slice/feature

  if (oRow < gradOutput.getSize(2) && oColumn < gradOutput.getSize(3)) {
    float *idx = &indices[slice][oFrame][oRow][oColumn];
    int iFrame  = ((unsigned char*)(idx))[0] + oFrame * dT;
    int iRow    = ((unsigned char*)(idx))[1] + oRow * dH;
    int iColumn = ((unsigned char*)(idx))[2] + oColumn * dW;
    atomicAdd(&gradInput[slice][iFrame][iRow][iColumn],
              gradOutput[slice][oFrame][oRow][oColumn]);
  }
}

static int cunn_VolumetricMaxPooling_updateGradInput(lua_State *L) {
  // State
  THCState *state = getCutorchState(L);
  // Input
  THCudaTensor* input = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 2, "torch.CudaTensor"));
  // gradOutput
  THCudaTensor* gradOutput = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 3, "torch.CudaTensor"));
  // Params
  int dT = luaT_getfieldcheckint(L, 1, "dT");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");

  // Indices
  THCudaTensor* indices = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "indices", "torch.CudaTensor"));
  // gradInput
  THCudaTensor* gradInput = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "gradInput", "torch.CudaTensor"));

  // Resize and initialize result tensor.
  THCudaTensor_resizeAs(state, gradInput, input);
  THCudaTensor_zero(state, gradInput);

  int batchSize;
  int inputSlices;

  int outputTime;
  int outputHeight;
  int outputWidth;

  THAssert(THCudaTensor_checkGPU(state, 4, input, indices, gradOutput, gradInput));

  if (THCudaTensor_nDimension(state, input) == 4) { /* 4D */
    batchSize = 1;
    inputSlices  = THCudaTensor_size(state, input, 0);

    outputTime   = THCudaTensor_size(state, gradOutput, 1);
    outputHeight = THCudaTensor_size(state, gradOutput, 2);
    outputWidth  = THCudaTensor_size(state, gradOutput, 3);
  } else {
    batchSize    = THCudaTensor_size(state, input, 0);
    inputSlices  = THCudaTensor_size(state, input, 1);

    outputTime   = THCudaTensor_size(state, gradOutput, 2);
    outputHeight = THCudaTensor_size(state, gradOutput, 3);
    outputWidth  = THCudaTensor_size(state, gradOutput, 4);
  }

  gradOutput = THCudaTensor_newContiguous(state, gradOutput);

  // Collapse batch and feature dimensions
  THCDeviceTensor<float, 4> cudaGradInput;
  THCDeviceTensor<float, 4> cudaGradOutput;
  if (THCudaTensor_nDimension(state, input) == 4) {
    cudaGradInput  = toDeviceTensor<float, 4>(state, gradInput);
    cudaGradOutput = toDeviceTensor<float, 4>(state, gradOutput);
  } else {
    cudaGradInput =
      toDeviceTensor<float, 5>(state, gradInput).downcastOuter<4>();
    cudaGradOutput =
      toDeviceTensor<float, 5>(state, gradOutput).downcastOuter<4>();
  }

  THLongStorage *indicesSize = THLongStorage_newWithSize(4);
  long indicesSizeRaw[4] = {batchSize * inputSlices,
                           outputTime, outputHeight, outputWidth};
  THLongStorage_rawCopy(indicesSize, indicesSizeRaw);
  THCudaTensor *indices1 = THCudaTensor_newWithStorage(
    state, THCudaTensor_storage(state, indices),
    THCudaTensor_storageOffset(state, indices), indicesSize, NULL);
  THLongStorage_free(indicesSize);

  THCDeviceTensor<float, 4> cudaIndices =
    toDeviceTensor<float, 4>(state, indices1);

  dim3 block(32, 8);
  dim3 grid(THCCeilDiv(outputWidth, static_cast<int>(block.x)),
            THCCeilDiv(outputHeight, static_cast<int>(block.y)),
            outputTime * inputSlices * batchSize);

  cuda_VolumetricMaxPooling_updateGradInput<<<grid, block,
    0, THCState_getCurrentStream(state)>>>(cudaGradOutput,
                                           cudaIndices,
                                           cudaGradInput,
                                           dT, dH, dW);
  // cleanup
  THCudaTensor_free(state, gradOutput);
  THCudaTensor_free(state, indices1);

  return 1;
}

static const struct luaL_Reg cunn_VolumetricMaxPooling__ [] = {
  {"VolumetricMaxPooling_updateOutput", cunn_VolumetricMaxPooling_updateOutput},
  {"VolumetricMaxPooling_updateGradInput",
   cunn_VolumetricMaxPooling_updateGradInput},
  {NULL, NULL}
};

void cunn_VolumetricMaxPooling_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_VolumetricMaxPooling__, "nn");
  lua_pop(L,1);
}
