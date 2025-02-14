﻿#include "cuda_runtime.h"
#include "cooperative_groups.h"
#include <thrust/scan.h>
#include <thrust/execution_policy.h>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include "../../bit_functions.cuh"

#define MAX(a,b) (((a)>(b)) ? (a) : (b))


namespace cg = cooperative_groups;

typedef struct segment {
	WORD_TYPE l_end_type;
	int l_end_len;

	WORD_TYPE r_end_type;
	int r_end_len;
} segment;

__device__ int get_segmentlen_inblock_sync(bool* is_begin, WORD_TYPE w_type, void* smem_ptr, int lane_id, int warp_id, int warps_count)
{
	segment* segments = (segment*)smem_ptr;

	bool am_last_beginning_inwarp = false;
	unsigned warp_begins_mask = __ballot_sync(FULL_MASK, *is_begin);
	int segment_len = 0;
	if (*is_begin)
	{																									// find ID of the next thread-beginning and thus the length of the section
		segment_len = (lane_id == warpSize - 1) ? 0 : __ffs(warp_begins_mask >> (lane_id + 1));			// note: bit shift "(int) >> 32" is not defined
																										// note: __ffs(0) = 0
		if (segment_len == 0)	// the last thread-beginning in warp
		{
			am_last_beginning_inwarp = true;
			segment_len = (warp_id < warps_count - 1) ? (warpSize - lane_id) : (warps_count*warpSize - threadIdx.x);
																										// considers case of the last thread-beginning in the last warp in block
																										// when inputSize is not divisible by 32
			segments[warp_id].r_end_type = w_type;
			segments[warp_id].r_end_len = segment_len;
		}
		if (lane_id == 0)		// the first thread-beginning in warp
		{
			segments[warp_id].l_end_type = w_type;
			segments[warp_id].l_end_len = segment_len;
		}
	}
	__syncthreads();

	if (*is_begin)
	{
		if (warp_id > 0 && lane_id == 0 && w_type != TAIL_WORD &&										// check if the first thread-beginning in warp is really
			(segments[warp_id - 1].r_end_type == w_type))												// thread-beginning in the context of the block...
		{
			*is_begin = false;
			am_last_beginning_inwarp = false;
		}

		if (am_last_beginning_inwarp)																	// ...if not, the last thread-beginning form prev. warp should add sth to its `segment_len`
		{
			for (int i = warp_id + 1; i < warps_count && segments[i].l_end_type == w_type; i++)
			{
				segment_len += segments[i].l_end_len;		// check types
				if (segments[i].l_end_len != warpSize)
					break;
			}
		}
	}
	__syncthreads();

	return segment_len;
}

// taken from https://github.com/NVIDIA/cuda-samples/blob/master/Samples/shfl_scan/shfl_scan.cu
// not work-efficient implementation
// TODO: do better implementation
// TODO: scan should be exclusive
__device__ void inclusive_scan_inblock_sync(int* value, void* smem_ptr, int lane_id, int warp_id, int warps_count)
{
	int* sums = (int*)smem_ptr;

	// in-warp scan
	for (int i = 1; i <= warpSize; i *= 2)
	{
		int n = __shfl_up_sync(FULL_MASK, *value, i);	// add width as argument???

		if (lane_id >= i)
			*value = *value + n;
	}
	if (warps_count == 1)
		return;

	// inter-warp scan
	if (lane_id == warpSize - 1)
		sums[warp_id] = *value;
	__syncthreads();

	// the same shfl scan operation, but performed on warp sums
	// this can be safely done by a single warp, since there is maximum of 32 warps in a block
	if (warp_id == 0 && lane_id < warps_count)
	{
		int warp_sum = sums[lane_id];

		int mask = (1 << warps_count) - 1;
		for (int i = 1; i <= warps_count; i *= 2)
		{
			int n = __shfl_up_sync(mask, warp_sum, i);
			if (lane_id >= i)
				warp_sum += n;
		}
		sums[lane_id] = warp_sum;
	}
	__syncthreads();

	if (warp_id > 0)
		*value = *value + sums[warp_id - 1];
	__syncthreads();
}



__device__ inline bool calc_segmentlen_ingrid_sync(int* segment_len, int* index, bool* is_begin, WORD_TYPE w_type, void* smem_ptr, void* output, int lane_id, int warp_id, int warps_count, cg::grid_group grid)
{
	segment* block_segments = (segment*)output;															// this allocation is just being reused
	unsigned* block_begins_masks = (unsigned*)smem_ptr;

	// find the last thread-beginning in block
	unsigned warp_begins_mask = __ballot_sync(FULL_MASK, *is_begin);
	if (lane_id == 0)
		block_begins_masks[warp_id] = warp_begins_mask;
	__syncthreads();

	if (threadIdx.x < warps_count)																		// find last warp in block which contains any thread-beginning
	{
		unsigned begins_mask = block_begins_masks[threadIdx.x];
		unsigned is_mask_nonzero = __ballot_sync(__activemask(), begins_mask != EMPTY_MASK);
		if (threadIdx.x == 0)
			block_begins_masks[0] = warpSize - 1 - __clz(is_mask_nonzero);								// write its warp_id in shared memory
	}
	__syncthreads();

	bool am_last_beginning_inblock = false;
	if (warp_id == block_begins_masks[0])																// now we find last thread-beginning in block (in previously found warp)
	{
		int lane = warpSize - 1 - __clz(warp_begins_mask);	// lane_id of this thread
		if (lane_id == lane)
		{
			am_last_beginning_inblock = true;

			block_segments[blockIdx.x].r_end_type = w_type;
			block_segments[blockIdx.x].r_end_len = *segment_len;
		}
	}
	if (threadIdx.x == 0)						// first thread-beginning in block
	{
		block_segments[blockIdx.x].l_end_type = w_type;
		block_segments[blockIdx.x].l_end_len = *segment_len;
	}
	grid.sync();

	bool* decrement_index = (bool*)smem_ptr;

	if (threadIdx.x == 0)
		*decrement_index = false;
	__syncthreads();
	if (*is_begin)
	{
		if (blockIdx.x > 0 && threadIdx.x == 0 && w_type != TAIL_WORD &&								// check if the first thread-beginning in block is really
			block_segments[blockIdx.x - 1].r_end_type == w_type)										// thread-beginning in the context of the grid...
		{
			*is_begin = false;
			am_last_beginning_inblock = false;
			*decrement_index = true;
		}

		if (am_last_beginning_inblock)																	// ...if not, the last thread-beginning form prev. block should add sth to its `segment_len`
		{
			for (int i = blockIdx.x + 1; i < gridDim.x && block_segments[i].l_end_type == w_type; i++)
			{
				*segment_len = (*segment_len) + block_segments[i].l_end_len;		// check types
				if (block_segments[i].l_end_len != blockDim.x)
					break;
			}
		}
	}
	__syncthreads();
	if (*decrement_index)
		*index = (*index) - 1;
	grid.sync();
	return am_last_beginning_inblock;

}


// kernel assumes that grid is 1D
__global__ void SharedMemKernel(UINT* input, int inputSize, UINT* output, size_t* outputSize)
{
	extern __shared__ int smem_ptr[];

	const int thread_id = blockIdx.x * blockDim.x + threadIdx.x;
	const int lane_id = threadIdx.x % warpSize;
	const int warp_id = threadIdx.x / warpSize;
	int warps_count;
	if ((blockIdx.x + 1)*blockDim.x > inputSize)	// last block can enter here
	{
		warps_count = (inputSize - blockIdx.x*blockDim.x) / warpSize;
		if (inputSize % warpSize != 0)
			warps_count++;
	}
	else
		warps_count = blockDim.x / warpSize;

	UINT gulp;
	if (thread_id < inputSize)
		gulp = input[thread_id];
	WORD_TYPE w_type = get_word_type(gulp);

	// is this thread the beginning of a section?
	bool is_begin = false;
	char prev_type = __shfl_up_sync(FULL_MASK, w_type, 1);
	if (thread_id < inputSize)
	{
		is_begin = (w_type == TAIL_WORD) || (w_type != prev_type);
		if (lane_id == 0)
			is_begin = true;
	}

	int segment_len = get_segmentlen_inblock_sync(&is_begin, w_type, smem_ptr, lane_id, warp_id, warps_count);
	// every thread-beginning knows its segment's length (in-block boundaries)
	
	int index = is_begin ? 1 : 0;
	__syncthreads();
	inclusive_scan_inblock_sync(&index, smem_ptr, lane_id, warp_id, warps_count);
	// now index is correct in block boundaries

	// ================
	// INTER-BLOCKS STEP
	// ================
	cg::grid_group grid = cg::this_grid();
	bool am_last_beginning_inblock = calc_segmentlen_ingrid_sync(&segment_len, &index, &is_begin, w_type, smem_ptr, output, lane_id, warp_id, warps_count, grid);
	// INTER-BLOCKS SCAN
	// write block_sum to global memory
	UINT* block_sums = output;		// TODO: possible to test. Allocate memory normally.
	bool* has_last_beginning = (bool*)smem_ptr;
	if (threadIdx.x == 0)
		*has_last_beginning = false;
	__syncthreads();
	if (am_last_beginning_inblock)
	{
		*has_last_beginning = true;
		block_sums[blockIdx.x] = index;
	}
	__syncthreads();
	if (!(*has_last_beginning))
	{
		if (threadIdx.x == warps_count * warpSize - 1)
			block_sums[blockIdx.x] = index;
	}
	grid.sync();


	// Kernel assumes that there are at least as many threads in a block as the total number of blocks.
	// This assumption makes sense since this kernel is cooperative.
	// Indeed, there ain't many blocks then (usually).
	int block_sum = 0;
	if (thread_id < gridDim.x)
		block_sum = block_sums[thread_id];
	grid.sync();

	inclusive_scan_inblock_sync(&block_sum, smem_ptr, lane_id, warp_id, warps_count);
	if (thread_id < gridDim.x)
		block_sums[thread_id] = block_sum;
	grid.sync();

	if (blockIdx.x > 0)
		index += block_sums[blockIdx.x - 1];
	grid.sync();

	if (is_begin)
	{
		if (w_type == EMPTY_WORD)
			output[index - 1] = get_compressed(segment_len, 0);
		else if (w_type == FULL_WORD)
			output[index - 1] = get_compressed(segment_len, 1);
		else
			output[index - 1] = gulp;
	}
	if (thread_id == inputSize-1)
		*outputSize = index;
}

// return size of output array if everything successful
// -1 else
long long LaunchKernel(int blocks, int threads_per_block, UINT* d_input, int size, UINT* d_output, size_t* d_outputSize)
{
	int device = 0;
	cudaDeviceProp deviceProp;
	CUDA_CHECK(cudaGetDeviceProperties(&deviceProp, device), Fail);

	int warps_count = threads_per_block / deviceProp.warpSize;											// calc size of needed shared memory (per block)
	if (threads_per_block % deviceProp.warpSize != 0)
		warps_count++;
	size_t smem_size = MAX(MAX(sizeof(segment), sizeof(int)), sizeof(unsigned));
	smem_size = smem_size * warps_count;

	int numBlocksPerSm = 0;																				// calc max number of blocks in coop. launch
	CUDA_CHECK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&numBlocksPerSm, SharedMemKernel, threads_per_block, smem_size), Fail);
	int maxCoopBlocks = deviceProp.multiProcessorCount * numBlocksPerSm;
	// printf("needed blocks: %d, max blocks: %d\n", blocks, maxCoopBlocks);

	if (blocks > maxCoopBlocks && threads_per_block < maxCoopBlocks)
	{
		printf("insufficient number of threads_per_block to make cooperative scan on whole grid\n");	// this can only happen when GPU has very many of SMs
		return -1;																						// (or more precisely: cooperative launch can handle many blocks)
	}																									// and blockSize is smaller than that
	
	int maxGridSize = maxCoopBlocks * threads_per_block;
	void* params[4];

	size_t outputSize = 0;
	size_t size_left = size;
	int blocks_left = blocks;

	UINT* d_outp = d_output;
	UINT* d_inp = d_input;
	params[0] = &d_inp;
	params[1] = &maxGridSize;
	params[2] = &d_outp;
	params[3] = &d_outputSize;

	// int noOfPacks = blocks / maxCoopBlocks;
	// int x = 0;
	// if (blocks % maxCoopBlocks != 0)
	// 	noOfPacks++;
	while (blocks_left > maxCoopBlocks)																		// if one coop. launch cannot handle the whole input, handle it in parts
	{
		CUDA_CHECK(cudaLaunchCooperativeKernel((void*)SharedMemKernel, maxCoopBlocks, threads_per_block, params, smem_size), Fail);
		CUDA_CHECK(cudaGetLastError(), Fail);
		CUDA_CHECK(cudaDeviceSynchronize(), Fail);
		
		size_t oSizeTmp;
		CUDA_CHECK(cudaMemcpy(&oSizeTmp, d_outputSize, sizeof(size_t), cudaMemcpyDeviceToHost), Fail);
		// CUDA_CHECK(cudaMemcpy(outp_curr_ptr, *(params[2]), outputSize * sizeof(UINT), cudaMemcpyDeviceToHost), Fail);
		d_inp += maxGridSize;
		d_outp += oSizeTmp;
		outputSize += oSizeTmp;

		blocks_left -= maxCoopBlocks;
		size_left -= maxGridSize;
	}
	if (blocks_left > 0)																				// handle the rest of input
	{
		params[1] = &size_left;
		CUDA_CHECK(cudaLaunchCooperativeKernel((void*)SharedMemKernel, blocks_left, threads_per_block, params, smem_size), Fail);
		CUDA_CHECK(cudaGetLastError(), Fail);
		CUDA_CHECK(cudaDeviceSynchronize(), Fail);
		
		size_t oSizeTmp;
		CUDA_CHECK(cudaMemcpy(&oSizeTmp, d_outputSize, sizeof(size_t), cudaMemcpyDeviceToHost), Fail);
		outputSize += oSizeTmp;
	}

	int threads_p_block = 512;
	int blcks = outputSize / threads_p_block;
	if (outputSize % threads_p_block != 0)
		blcks++;
    ballot_warp_merge<<<blcks, threads_p_block>>>(outputSize, d_output, d_input);						// join parts
	CUDA_CHECK(cudaGetLastError(), Fail);
	CUDA_CHECK(cudaDeviceSynchronize(), Fail);

	UINT* final_end = thrust::remove_if(thrust::device, d_input, d_input + outputSize, wah_zero());		// remove leftover gaps
	int final_count = final_end - d_input;

	return final_count;

Fail:
	return -1;
}


bool ensure_cooperativity_support()
{
	cudaDeviceProp deviceProp = { 0 };

	int device;
	CUDA_CHECK(cudaGetDevice(&device), Finish);

	CUDA_CHECK(cudaGetDeviceProperties(&deviceProp, device), Finish);
	if (!deviceProp.cooperativeLaunch)
	{
		printf("\nSelected GPU (%d) does not support Cooperative Kernel Launch, Waiving the run\n", device);
		return false;
	}
	return true;

Finish:
	return false;
}

UINT* SharedMemWAH(int size, UINT* input)
{
	if (size < 1 || input == nullptr)
	{
		printf("bad argument\n");
		return nullptr;
	}
	if (!ensure_cooperativity_support())
		 return nullptr;
		 
	UINT* d_input;
	UINT* d_output;
	size_t* d_outputSize;
	CUDA_CHECK(cudaMalloc((void**)&d_input, size * sizeof(UINT)), Fin);		// reinterpret_cast<>
	CUDA_CHECK(cudaMalloc((void**)&d_output, size * sizeof(UINT)), FreeInput);
	CUDA_CHECK(cudaMalloc((void**)&d_outputSize, sizeof(size_t)), FreeOutput);
	CUDA_CHECK(cudaMemcpy(d_input, input, size * sizeof(UINT), cudaMemcpyHostToDevice), Free);

	int threads_per_block = 1024;
	int blocks = size / threads_per_block;
	if (size % threads_per_block != 0)
		blocks++;

	// SharedMemKernel<<<blocks, threads_per_block>>>(d_input, size, d_output, d_outputSize);
	long long outputSize = LaunchKernel(blocks, threads_per_block, d_input, size, d_output, d_outputSize);
	if (outputSize < 0)
	{
		printf("something went wrong\n");
		goto Free;
	}
	UINT* result = new UINT[outputSize];
	CUDA_CHECK(cudaMemcpy(result, d_input, outputSize * sizeof(UINT), cudaMemcpyDeviceToHost), Free);

Free:
	CUDA_CHECK(cudaFree(d_outputSize), FreeOutput);
FreeOutput:
	CUDA_CHECK(cudaFree(d_output), FreeInput);
FreeInput:
	CUDA_CHECK(cudaFree(d_input), Fin);
Fin:
	return result;
}
