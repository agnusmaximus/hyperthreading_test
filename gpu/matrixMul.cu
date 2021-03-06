/**
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

/**
 * Matrix multiplication: C = A * B.
 * Host code.
 *
 * This sample implements matrix multiplication as described in Chapter 3
 * of the programming guide.
 * It has been written for clarity of exposition to illustrate various CUDA
 * programming principles, not with the goal of providing the most
 * performant generic kernel for matrix multiplication.
 *
 * See also:
 * V. Volkov and J. Demmel, "Benchmarking GPUs to tune dense linear algebra,"
 * in Proc. 2008 ACM/IEEE Conf. on Supercomputing (SC '08),
 * Piscataway, NJ: IEEE Press, 2008, pp. Art. 31:1-11.
 */

// System includes
#include <stdio.h>
#include <assert.h>

// CUDA runtime
#include <cuda_runtime.h>

// Helper functions and utilities to work with CUDA
#include <helper_functions.h>

static __device__ __inline__ int __mysmid(){
  int smid;
  asm volatile("mov.u32 %0, %%smid;" : "=r"(smid));
  return smid;
}


template <int BLOCK_SIZE> __global__ void
matrixMulCUDASingleBlock(float *C, float *A, float *B, int hA, int wA, int wB, 
			 int should_profile, char *name) 
{

  // Thread index
  int tx = threadIdx.x;
  int ty = threadIdx.y;

  long long int start_time, end_time;

  if (should_profile) {
    if (tx == 0 && ty == 0) {
      start_time = clock64();
    }
  }

  for (int x_a = 0; x_a < wA; x_a += BLOCK_SIZE) {
    for (int y_a = 0; y_a < hA; y_a += BLOCK_SIZE) {
      for (int x_b = 0; x_b < wB; x_b += BLOCK_SIZE) {
	// Load blocks of size BLOCK_SIZE: <x_a, y_a>, <x_b, x_a>
        __shared__ float As[BLOCK_SIZE][BLOCK_SIZE];
        __shared__ float Bs[BLOCK_SIZE][BLOCK_SIZE];
	As[ty][tx] = A[(y_a + ty) * wA + x_a + tx];
	Bs[ty][tx] = B[(x_a + ty) * wB + x_b + tx];
	__syncthreads();

	float Csub = 0;
	for (int k = 0; k < BLOCK_SIZE; k++) {
	  Csub += As[ty][k] * Bs[k][tx];
	}


	// Block of c: <x_b, y_a>
	int c = y_a * wB + x_b;
	C[c + wB * ty + tx] += Csub;
	__syncthreads();
      }
    }
  }

  if (should_profile) {
    if (tx == 0 && ty == 0) {
      end_time = clock64();

      printf("- %d SM_%d_%s_nthreads=%d %lld %lld\n", __mysmid(), __mysmid(), name, BLOCK_SIZE*BLOCK_SIZE, start_time, end_time);
    }
  }
}

/**
 * Matrix multiplication (CUDA Kernel) on the device: C = A * B
 * wA is A's width and wB is B's width
 */
template <int BLOCK_SIZE> __global__ void
matrixMulCUDA(float *C, float *A, float *B, int wA, int wB)
{
    // Block index
    int bx = blockIdx.x;
    int by = blockIdx.y;

    // Thread index
    int tx = threadIdx.x;
    int ty = threadIdx.y;

    // Index of the first sub-matrix of A processed by the block
    int aBegin = wA * BLOCK_SIZE * by;

    // Index of the last sub-matrix of A processed by the block
    int aEnd   = aBegin + wA - 1;

    // Step size used to iterate through the sub-matrices of A
    int aStep  = BLOCK_SIZE;

    // Index of the first sub-matrix of B processed by the block
    int bBegin = BLOCK_SIZE * bx;

    // Step size used to iterate through the sub-matrices of B
    int bStep  = BLOCK_SIZE * wB;

    // Csub is used to store the element of the block sub-matrix
    // that is computed by the thread
    float Csub = 0;

    // Loop over all the sub-matrices of A and B
    // required to compute the block sub-matrix
    for (int a = aBegin, b = bBegin;
         a <= aEnd;
         a += aStep, b += bStep)
    {

        // Declaration of the shared memory array As used to
        // store the sub-matrix of A
        __shared__ float As[BLOCK_SIZE][BLOCK_SIZE];

        // Declaration of the shared memory array Bs used to
        // store the sub-matrix of B
        __shared__ float Bs[BLOCK_SIZE][BLOCK_SIZE];

        // Load the matrices from device memory
        // to shared memory; each thread loads
        // one element of each matrix
        As[ty][tx] = A[a + wA * ty + tx];
        Bs[ty][tx] = B[b + wB * ty + tx];

        // Synchronize to make sure the matrices are loaded
        __syncthreads();

        // Multiply the two matrices together;
        // each thread computes one element
        // of the block sub-matrix
#pragma unroll

        for (int k = 0; k < BLOCK_SIZE; ++k)
        {
            Csub += As[ty][k] * Bs[k][tx];
        }

        // Synchronize to make sure that the preceding
        // computation is done before loading two new
        // sub-matrices of A and B in the next iteration
        __syncthreads();
    }

    // Write the block sub-matrix to device memory;
    // each thread writes one element
    int c = wB * BLOCK_SIZE * by + BLOCK_SIZE * bx;
    C[c + wB * ty + tx] = Csub;
}

void constantInit(float *data, int size, float val)
{
    for (int i = 0; i < size; ++i)
    {
        data[i] = val;
    }
}

/**
 * Run a simple test of matrix multiplication using CUDA
 */
int matrixMultiply(int argc, char **argv, int block_size, dim3 &dimsA, dim3 &dimsB)
{
    // Allocate host memory for matrices A and B
    unsigned int size_A = dimsA.x * dimsA.y;
    unsigned int mem_size_A = sizeof(float) * size_A;
    float *h_A = (float *)malloc(mem_size_A);
    unsigned int size_B = dimsB.x * dimsB.y;
    unsigned int mem_size_B = sizeof(float) * size_B;
    float *h_B = (float *)malloc(mem_size_B);

    // Initialize host memory
    const float valB = 0.01f;
    constantInit(h_A, size_A, 1.0f);
    constantInit(h_B, size_B, valB);

    // Allocate device memory
    float *d_A, *d_B, *d_C;

    // Allocate host matrix C
    dim3 dimsC(dimsB.x, dimsA.y, 1);
    unsigned int mem_size_C = dimsC.x * dimsC.y * sizeof(float);
    float *h_C = (float *) malloc(mem_size_C);

    if (h_C == NULL)
    {
        fprintf(stderr, "Failed to allocate host matrix C!\n");
        exit(EXIT_FAILURE);
    }

    cudaError_t error;

    error = cudaMalloc((void **) &d_A, mem_size_A);

    if (error != cudaSuccess)
    {
        printf("cudaMalloc d_A returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    error = cudaMalloc((void **) &d_B, mem_size_B);

    if (error != cudaSuccess)
    {
        printf("cudaMalloc d_B returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    error = cudaMalloc((void **) &d_C, mem_size_C);

    if (error != cudaSuccess)
    {
        printf("cudaMalloc d_C returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    cudaMemset(d_C, 0, mem_size_C);

    // copy host memory to device
    error = cudaMemcpy(d_A, h_A, mem_size_A, cudaMemcpyHostToDevice);

    if (error != cudaSuccess)
    {
        printf("cudaMemcpy (d_A,h_A) returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    error = cudaMemcpy(d_B, h_B, mem_size_B, cudaMemcpyHostToDevice);

    if (error != cudaSuccess)
    {
        printf("cudaMemcpy (d_B,h_B) returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    // Setup execution parameters
    dim3 threads(block_size, block_size);
    dim3 grid(dimsB.x / threads.x, dimsA.y / threads.y);
    char *device_name, *host_name =  "MatrixMulOnePerSM";
    cudaMalloc(&device_name, sizeof(char) * strlen(host_name) + 1);
    cudaMemcpy(device_name, host_name, strlen(host_name), cudaMemcpyHostToDevice);

    // Performs warmup operation using matrixMul CUDA kernel
    if (block_size == 16)
      {
	//matrixMulCUDA<16><<< grid, threads >>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
	matrixMulCUDASingleBlock<16><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }
    else if (block_size == 8) 
      {
	matrixMulCUDASingleBlock<8><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }
    else
      {
	//matrixMulCUDA<32><<< grid, threads >>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
	matrixMulCUDASingleBlock<32><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }

    cudaDeviceSynchronize();

    // Allocate CUDA events that we'll use for timing
    cudaEvent_t start;
    error = cudaEventCreate(&start);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    cudaEvent_t stop;
    error = cudaEventCreate(&stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Record the start event
    error = cudaEventRecord(start, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Execute the kernel
    int nIter = 300;

    for (int j = 0; j < nIter; j++)
    {
        if (block_size == 16)
        {
	  matrixMulCUDASingleBlock<16><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
        }
	else if (block_size == 8) 
	  {
	    matrixMulCUDASingleBlock<8><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	  }
        else
        {
	  matrixMulCUDASingleBlock<32><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
        }
    }

    // Record the stop event
    error = cudaEventRecord(stop, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Wait for the stop event to complete
    error = cudaEventSynchronize(stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    float msecTotal = 0.0f;
    error = cudaEventElapsedTime(&msecTotal, start, stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Compute and print the performance
    float msecPerMatrixMul = msecTotal / nIter;
    double flopsPerMatrixMul = 2.0 * (double)dimsA.x * (double)dimsA.y * (double)dimsB.x;
    double gigaFlops = (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul / 1000.0f);
    printf(
        "Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops, WorkgroupSize= %u threads/block\n",
        gigaFlops,
        msecPerMatrixMul,
        flopsPerMatrixMul,
        threads.x * threads.y);

    // Correctness check
    cudaMemset(d_C, 0, mem_size_C);

    if (block_size == 16)
      {
	matrixMulCUDASingleBlock<16><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }
    else if (block_size == 8) 
      {
	matrixMulCUDASingleBlock<8><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }
    else
      {
	matrixMulCUDASingleBlock<32><<<1, threads>>>(d_C, d_A, d_B, dimsA.y, dimsA.x, dimsB.x, 0, device_name);
      }
    
    // Copy result from device to host
    error = cudaMemcpy(h_C, d_C, mem_size_C, cudaMemcpyDeviceToHost);

    if (error != cudaSuccess)
    {
        printf("cudaMemcpy (h_C,d_C) returned error code %d, line(%d)\n", error, __LINE__);
        exit(EXIT_FAILURE);
    }

    printf("Checking computed result for correctness: ");
    bool correct = true;

    // test relative error by the formula
    //     |<x, y>_cpu - <x,y>_gpu|/<|x|, |y|>  < eps
    double eps = 1.e-6 ; // machine zero

    for (int i = 0; i < (int)(dimsC.x * dimsC.y); i++)
    {
        double abs_err = fabs(h_C[i] - (dimsA.x * valB));
        double dot_length = dimsA.x;
        double abs_val = fabs(h_C[i]);
        double rel_err = abs_err/abs_val/dot_length ;

        if (rel_err > eps)
        {
	  printf("Error! Matrix[%05d]=%.8f, ref=%.8f error term is > %E\n", i, h_C[i], dimsA.x*valB, eps);
	  correct = false;
        }
    }

    printf("%s\n", correct ? "Result = PASS" : "Result = FAIL");

    // Clean up memory
    free(h_A);
    free(h_B);
    free(h_C);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);

    printf("\nNOTE: The CUDA Samples are not meant for performance measurements. Results may vary when GPU Boost is enabled.\n");

    // cudaDeviceReset causes the driver to clean up all state. While
    // not mandatory in normal operation, it is good practice.  It is also
    // needed to ensure correct operation when the application is being
    // profiled. Calling cudaDeviceReset causes all profile data to be
    // flushed before the application exits
    cudaDeviceReset();

    if (correct)
    {
        return EXIT_SUCCESS;
    }
    else
    {
        return EXIT_FAILURE;
    }
}

/**
 * Run a simple test of matrix multiplication using CUDA on every SM
 */
int matrixMultiplyOnePerSM(int argc, char **argv, int block_size, dim3 &dimsA, dim3 &dimsB)
{
    // Allocate host memory for matrices A and B
    unsigned int size_A = dimsA.x * dimsA.y;
    unsigned int mem_size_A = sizeof(float) * size_A;
    float *h_A = (float *)malloc(mem_size_A);
    unsigned int size_B = dimsB.x * dimsB.y;
    unsigned int mem_size_B = sizeof(float) * size_B;
    float *h_B = (float *)malloc(mem_size_B);

    // Initialize host memory
    const float valB = 0.01f;
    constantInit(h_A, size_A, 1.0f);
    constantInit(h_B, size_B, valB);

    // Get number of SMs
    struct cudaDeviceProp devProp;
    cudaGetDeviceProperties(&devProp, 0);
    int num_sm = devProp.multiProcessorCount;
    printf("Number of SMs: %d\n", num_sm);

    // Allocate device memory
    float **d_A, **d_B, **d_C;
    d_A = (float **)malloc(sizeof(float *) * num_sm);
    d_B = (float **)malloc(sizeof(float *) * num_sm);
    d_C = (float **)malloc(sizeof(float *) * num_sm);    
    cudaStream_t *streams;
    streams = (cudaStream_t *)malloc(sizeof(cudaStream_t) * num_sm);
    
    // Allocate host matrix C
    dim3 dimsC(dimsB.x, dimsA.y, 1);
    unsigned int mem_size_C = dimsC.x * dimsC.y * sizeof(float);
    float *h_C = (float *) malloc(mem_size_C);

    if (h_C == NULL)
    {
        fprintf(stderr, "Failed to allocate host matrix C!\n");
        exit(EXIT_FAILURE);
    }

    cudaError_t error;

    for (int i = 0; i < num_sm; i++) {
      error = cudaStreamCreate(&streams[i]);
      if (error != cudaSuccess) {
	printf("cudaStreamCreate returned error code %d, line(%d)\n", error, __LINE__);
	exit(EXIT_FAILURE);
      }

      error = cudaMalloc((void **) &d_A[i], mem_size_A);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_A returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      error = cudaMalloc((void **) &d_B[i], mem_size_B);

      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_B returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      error = cudaMalloc((void **) &d_C[i], mem_size_C);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_C returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      cudaMemset(d_C, 0, mem_size_C);

      // copy host memory to device
      error = cudaMemcpy(d_A[i], h_A, mem_size_A, cudaMemcpyHostToDevice);
    
      
      if (error != cudaSuccess)
	{
	  printf("cudaMemcpy (d_A,h_A) returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}

      error = cudaMemcpy(d_B[i], h_B, mem_size_B, cudaMemcpyHostToDevice);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMemcpy (d_B,h_B) returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
    }

    // Setup execution parameters
    dim3 threads(block_size, block_size);
    dim3 grid(dimsB.x / threads.x, dimsA.y / threads.y);
    char *device_name, *host_name =  "MatrixMulOnePerSM";
    cudaMalloc(&device_name, sizeof(char) * strlen(host_name) + 1);
    cudaMemcpy(device_name, host_name, strlen(host_name)+1, cudaMemcpyHostToDevice);

    // Performs warmup operation using matrixMul CUDA kernel
    for (int i = 0; i < num_sm; i++) {
      if (block_size == 16)
	{
	  matrixMulCUDASingleBlock<16><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	}
      else if (block_size == 8) 
	{
	matrixMulCUDASingleBlock<8><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	}
      else
	{
	  matrixMulCUDASingleBlock<32><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	  
      }
    }

    cudaDeviceSynchronize();

    // Allocate CUDA events that we'll use for timing
    cudaEvent_t start;
    error = cudaEventCreate(&start);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    cudaEvent_t stop;
    error = cudaEventCreate(&stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Record the start event
    error = cudaEventRecord(start, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Execute the kernel
    int nIter = 300;

    for (int j = 0; j < nIter; j++)
    {
      for (int i = 0; i < num_sm; i++) {
        if (block_size == 16)
	  {
	    matrixMulCUDASingleBlock<16><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
	else if (block_size == 8) 
	  {
	    matrixMulCUDASingleBlock<8><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
        else
	  {
	    matrixMulCUDASingleBlock<32><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
      }
    }

    // Record the stop event
    error = cudaEventRecord(stop, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Wait for the stop event to complete
    error = cudaEventSynchronize(stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    float msecTotal = 0.0f;
    error = cudaEventElapsedTime(&msecTotal, start, stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Compute and print the performance
    float msecPerMatrixMul = msecTotal / nIter;
    double flopsPerMatrixMul = 2.0 * (double)dimsA.x * (double)dimsA.y * (double)dimsB.x * num_sm;
    double gigaFlops = (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul / 1000.0f);
    printf(
        "Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops, WorkgroupSize= %u threads/block\n",
        gigaFlops,
        msecPerMatrixMul,
        flopsPerMatrixMul,
        threads.x * threads.y);

    // Clean up memory
    free(h_A);
    free(h_B);
    free(h_C);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);

    printf("\nNOTE: The CUDA Samples are not meant for performance measurements. Results may vary when GPU Boost is enabled.\n");

    // cudaDeviceReset causes the driver to clean up all state. While
    // not mandatory in normal operation, it is good practice.  It is also
    // needed to ensure correct operation when the application is being
    // profiled. Calling cudaDeviceReset causes all profile data to be
    // flushed before the application exits
    cudaDeviceReset();

    return EXIT_SUCCESS;
}

/**
 * Run a simple test of matrix multiplication using CUDA on every SM
 */
int matrixMultiplyTwoPerSM(int argc, char **argv, int block_size, dim3 &dimsA, dim3 &dimsB)
{
    // Allocate host memory for matrices A and B
    unsigned int size_A = dimsA.x * dimsA.y;
    unsigned int mem_size_A = sizeof(float) * size_A;
    float *h_A = (float *)malloc(mem_size_A);
    unsigned int size_B = dimsB.x * dimsB.y;
    unsigned int mem_size_B = sizeof(float) * size_B;
    float *h_B = (float *)malloc(mem_size_B);

    // Initialize host memory
    const float valB = 0.01f;
    constantInit(h_A, size_A, 1.0f);
    constantInit(h_B, size_B, valB);

    // Get number of SMs
    struct cudaDeviceProp devProp;
    cudaGetDeviceProperties(&devProp, 0);
    int num_sm = devProp.multiProcessorCount;
    printf("Number of SMs: %d\n", num_sm);

    // Allocate device memory
    float **d_A, **d_B, **d_C;
    d_A = (float **)malloc(sizeof(float *) * num_sm * 2);
    d_B = (float **)malloc(sizeof(float *) * num_sm * 2);
    d_C = (float **)malloc(sizeof(float *) * num_sm * 2);    
    cudaStream_t *streams;
    streams = (cudaStream_t *)malloc(sizeof(cudaStream_t) * num_sm * 2);
    
    // Allocate host matrix C
    dim3 dimsC(dimsB.x, dimsA.y, 1);
    unsigned int mem_size_C = dimsC.x * dimsC.y * sizeof(float);
    float *h_C = (float *) malloc(mem_size_C);

    if (h_C == NULL)
    {
        fprintf(stderr, "Failed to allocate host matrix C!\n");
        exit(EXIT_FAILURE);
    }

    cudaError_t error;

    for (int i = 0; i < num_sm * 2; i++) {
      error = cudaStreamCreate(&streams[i]);
      if (error != cudaSuccess) {
	printf("cudaStreamCreate returned error code %d, line(%d)\n", error, __LINE__);
	exit(EXIT_FAILURE);
      }

      error = cudaMalloc((void **) &d_A[i], mem_size_A);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_A returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      error = cudaMalloc((void **) &d_B[i], mem_size_B);

      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_B returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      error = cudaMalloc((void **) &d_C[i], mem_size_C);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMalloc d_C returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
      
      cudaMemset(d_C, 0, mem_size_C);

      // copy host memory to device
      error = cudaMemcpy(d_A[i], h_A, mem_size_A, cudaMemcpyHostToDevice);
    
      
      if (error != cudaSuccess)
	{
	  printf("cudaMemcpy (d_A,h_A) returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}

      error = cudaMemcpy(d_B[i], h_B, mem_size_B, cudaMemcpyHostToDevice);
      
      if (error != cudaSuccess)
	{
	  printf("cudaMemcpy (d_B,h_B) returned error code %d, line(%d)\n", error, __LINE__);
	  exit(EXIT_FAILURE);
	}
    }

    // Setup execution parameters
    dim3 threads(block_size, block_size);
    dim3 grid(dimsB.x / threads.x, dimsA.y / threads.y);
    char *device_name, *host_name =  "MatrixMulTwoPerSM";
    cudaMalloc(&device_name, sizeof(char) * strlen(host_name) + 1);
    cudaMemcpy(device_name, host_name, strlen(host_name)+1, cudaMemcpyHostToDevice);    

    // Performs warmup operation using matrixMul CUDA kernel
    for (int i = 0; i < num_sm * 2; i++) {
      if (block_size == 16)
	{
	  matrixMulCUDASingleBlock<16><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	}
      else
	{
	  matrixMulCUDASingleBlock<32><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, 0, device_name);
	
	}}

    cudaDeviceSynchronize();

    // Allocate CUDA events that we'll use for timing
    cudaEvent_t start;
    error = cudaEventCreate(&start);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    cudaEvent_t stop;
    error = cudaEventCreate(&stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Record the start event
    error = cudaEventRecord(start, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Execute the kernel
    int nIter = 300;

    for (int j = 0; j < nIter; j++)
    {
      for (int i = 0; i < num_sm * 2; i++) {
        if (block_size == 16)
	  {
	    matrixMulCUDASingleBlock<16><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
        else if (block_size == 8)
	  {
	    matrixMulCUDASingleBlock<8><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
        else
	  {
	    matrixMulCUDASingleBlock<32><<<1, threads, 0, streams[i]>>>(d_C[i], d_A[i], d_B[i], dimsA.y, dimsA.x, dimsB.x, j==0, device_name);
	  }
      }
    }

    // Record the stop event
    error = cudaEventRecord(stop, NULL);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Wait for the stop event to complete
    error = cudaEventSynchronize(stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    float msecTotal = 0.0f;
    error = cudaEventElapsedTime(&msecTotal, start, stop);

    if (error != cudaSuccess)
    {
        fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }

    // Compute and print the performance
    float msecPerMatrixMul = msecTotal / nIter;
    double flopsPerMatrixMul = 2.0 * (double)dimsA.x * (double)dimsA.y * (double)dimsB.x * num_sm * 2;
    double gigaFlops = (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul / 1000.0f);
    printf(
        "Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops, WorkgroupSize= %u threads/block\n",
        gigaFlops,
        msecPerMatrixMul,
        flopsPerMatrixMul,
        threads.x * threads.y);

    // Clean up memory
    free(h_A);
    free(h_B);
    free(h_C);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);

    printf("\nNOTE: The CUDA Samples are not meant for performance measurements. Results may vary when GPU Boost is enabled.\n");

    // cudaDeviceReset causes the driver to clean up all state. While
    // not mandatory in normal operation, it is good practice.  It is also
    // needed to ensure correct operation when the application is being
    // profiled. Calling cudaDeviceReset causes all profile data to be
    // flushed before the application exits
    cudaDeviceReset();

    return EXIT_SUCCESS;
}

/**
 * Program main
 */
int main(int argc, char **argv)
{
    if (checkCmdLineFlag(argc, (const char **)argv, "help") ||
        checkCmdLineFlag(argc, (const char **)argv, "?"))
    {
        printf("Usage -device=n (n >= 0 for deviceID)\n");
        printf("      -wA=WidthA -hA=HeightA (Width x Height of Matrix A)\n");
        printf("      -wB=WidthB -hB=HeightB (Width x Height of Matrix B)\n");
        printf("  Note: Outer matrix dimensions of A & B matrices must be equal.\n");

        exit(EXIT_SUCCESS);
    }

    // By default, we use device 0, otherwise we override the device ID based on what is provided at the command line
    int devID = 0;

    if (checkCmdLineFlag(argc, (const char **)argv, "device"))
    {
        devID = getCmdLineArgumentInt(argc, (const char **)argv, "device");
        cudaSetDevice(devID);
    }

    cudaError_t error;
    cudaDeviceProp deviceProp;
    error = cudaGetDevice(&devID);

    if (error != cudaSuccess)
    {
        printf("cudaGetDevice returned error code %d, line(%d)\n", error, __LINE__);
    }

    error = cudaGetDeviceProperties(&deviceProp, devID);

    if (deviceProp.computeMode == cudaComputeModeProhibited)
    {
        fprintf(stderr, "Error: device is running in <Compute Mode Prohibited>, no threads can use ::cudaSetDevice().\n");
        exit(EXIT_SUCCESS);
    }


    // Use a larger block size for Fermi and above
    //int block_size = (deviceProp.major < 2) ? 16 : 32;
    int block_size = 8;

    dim3 dimsA(5*2*32, 5*2*32, 1);
    dim3 dimsB(5*4*32, 5*2*32, 1);

    // width of Matrix A
    if (checkCmdLineFlag(argc, (const char **)argv, "wA"))
    {
        dimsA.x = getCmdLineArgumentInt(argc, (const char **)argv, "wA");
    }

    // height of Matrix A
    if (checkCmdLineFlag(argc, (const char **)argv, "hA"))
    {
        dimsA.y = getCmdLineArgumentInt(argc, (const char **)argv, "hA");
    }

    // width of Matrix B
    if (checkCmdLineFlag(argc, (const char **)argv, "wB"))
    {
        dimsB.x = getCmdLineArgumentInt(argc, (const char **)argv, "wB");
    }

    // height of Matrix B
    if (checkCmdLineFlag(argc, (const char **)argv, "hB"))
    {
        dimsB.y = getCmdLineArgumentInt(argc, (const char **)argv, "hB");
    }

    if (dimsA.x != dimsB.y)
    {
        printf("Error: outer matrix dimensions must be equal. (%d != %d)\n",
               dimsA.x, dimsB.y);
        exit(EXIT_FAILURE);
    }

    matrixMultiply(argc, argv, block_size, dimsA, dimsB);
    int matrix_result = matrixMultiplyOnePerSM(argc, argv, block_size, dimsA, dimsB);
    matrix_result = matrixMultiplyTwoPerSM(argc, argv, block_size, dimsA, dimsB);

    exit(matrix_result);
}
