#ifndef _INCLUDED_MVNPDF
#define _INCLUDED_MVNPDF

#ifdef __cplusplus
extern "C" {
#endif

#include "mvnpdf.h"

#define BLOCK_SIZE 16
#define BLOCK_TOTAL 256

typedef struct {
  int data_per_block;
  int params_per_block;
} TuningInfo;


int smem_size() {
  int dev = 0;
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, dev);
  return deviceProp.sharedMemPerBlock;
}

int max_block_threads() {
  int dev = 0;
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, dev);
  return deviceProp.maxThreadsPerBlock;
}

int compute_shmem(PMatrix* data, PMatrix* params, int nparams, int ndata) {
  // to hold specified about of data, parameters, and results
  int result_space = nparams * ndata;
  int param_space = params->stride * nparams;
  int data_space = data->stride * ndata;

  return sizeof(float) * (result_space + param_space + data_space);
}

int next_pow2(int k, int pow2) {
  // next highest power of two
  while (k <= pow2 / 2) pow2 /= 2;
  return pow2;
}

int get_boxes(int n, int box_size) {
  // how many boxes of size box_size are needed to hold n things
  return (n + box_size - 1) / box_size;
}

void get_tuned_layout(TuningInfo* info, PMatrix* data, PMatrix* params) {
  // query the device for smem / max # of threads
  int max_smem = smem_size();
  int max_threads = max_block_threads();

  // at most max_block_params sets of density parameters per block
  // for low-dimensional data, better to do more?
  int max_block_params = 16;
  int params_per = max_block_params;
  if (params->rows < max_block_params)
	params_per = next_pow2(params->rows, max_block_params);

  // hide your kids, hide your wife (auto-tuning the GPU)
  int data_per;
  while (1) {
	data_per = max_threads / params_per;
	  while (compute_shmem(data, params, params_per, data_per) > max_smem) {
		if (data_per == 0)
		  break;
		data_per /=2;
	  }

	  // can't fit max_block_params sets of parameters into the shared memory,
	  // uh oh
	  if (data_per == 0) {
		params_per /= 2;

		// start over the tuning
		continue;
	  }
	  else break;
  }

  info->data_per_block = data_per;
  info->params_per_block = params_per;
}

void inline h_to_d(float* h_ptr, float* d_ptr, size_t n){
  cudaError_t error;
  CATCH_ERR(cudaMemcpy(d_ptr, h_ptr, n * sizeof(float), cudaMemcpyHostToDevice));
}

void inline d_to_h(float* d_ptr, float* h_ptr, size_t n){
  cudaError_t error;
  CATCH_ERR(cudaMemcpy(h_ptr, d_ptr, n * sizeof(float), cudaMemcpyDeviceToHost));
}

__device__ int next_multiple(int k, int mult) {
  if (k % mult)
	return k + (mult - k % mult);
  else
	return k;
}

/* Thread-Block design:
 * 1 thread per datum*density
 * Block grid(DATA_IN_BLOCK,DENSITIES_IN_BLOCK)
 * DATA_IN_BLOCK = # of datum per block
 * DENSITIES_IN_BLOCK = # of densities per block
 */
#define TWISTED_DENSITY
__global__ void mvNormalPDF(
                    REAL* inData, /** Data-vector; padded */
                    REAL* inDensityInfo, /** Density info; already padded */
                    REAL* outPDF, /** Resultant PDF */
                    int iD,
                    int iN,
                    int iTJ,
                    int isLogScaled
                ) {
    const int thidx = threadIdx.x;
    const int thidy = threadIdx.y;

    const int dataBlockIndex = blockIdx.x * DATA_IN_BLOCK;
    const int datumIndex = dataBlockIndex + thidx;

    const int densityBlockIndex = blockIdx.y * DENSITIES_IN_BLOCK;
    const int densityIndex = densityBlockIndex + thidy;

    #if defined(TWISTED_DENSITY)
        const int pdfIndex = blockIdx.x * DATA_IN_BLOCK * iTJ +
            blockIdx.y * DENSITIES_IN_BLOCK + thidy * iTJ + thidx;
    #else
        const int pdfIndex = datumIndex * iTJ + densityIndex;
    #endif

    extern __shared__ REAL sData[];
    REAL *densityInfo = sData;
    // do this for now, will be more efficient to pass them in as parameters?
    //-------------------------------------------------------
    int LOGDET_OFFSET = iD * (iD + 3) / 2;
    int MEAN_CHD_DIM = iD * (iD + 3) / 2    + 2;
    int PACK_DIM = 16;
    while (MEAN_CHD_DIM > PACK_DIM) {PACK_DIM += 16;}
    int DATA_PADDED_DIM = BASE_DATAPADED_DIM;
    while (iD > DATA_PADDED_DIM) {DATA_PADDED_DIM += BASE_DATAPADED_DIM;}
    //--------------------------------------------------

    const int data_offset = DENSITIES_IN_BLOCK * PACK_DIM;
    REAL *data = &sData[data_offset];

    #if defined(TWISTED_DENSITY)
        REAL *result_trans = &sData[data_offset+DATA_IN_BLOCK * iD];
    #endif

    //Read in data
    for(int chunk = 0; chunk < iD; chunk += DENSITIES_IN_BLOCK)
    if (chunk + thidy < iD ) {
        data[thidx * iD + chunk + thidy] = inData[DATA_PADDED_DIM*datumIndex + chunk + thidy];
    }


    // Read in density info by chunks
    for(int chunk = 0; chunk < PACK_DIM; chunk += DATA_IN_BLOCK) {
        if (chunk + thidx < PACK_DIM) {
            densityInfo[thidy * PACK_DIM + chunk + thidx] = inDensityInfo[PACK_DIM*densityIndex + chunk + thidx];
        }
    }
    __syncthreads();

    // Setup pointers
    REAL* tData = data+thidx*iD;
    REAL* tDensityInfo = densityInfo + thidy * PACK_DIM;


    REAL* tMean = tDensityInfo;         //do we need to unallocate shared/register variables?
    REAL* tSigma = tDensityInfo + iD;
    REAL  tP = tDensityInfo[LOGDET_OFFSET];
    REAL  tLogDet = tDensityInfo[LOGDET_OFFSET+1];

    // Do density calculation
    REAL discrim = 0;
    for(int i=0; i<iD; i++) {
        REAL sum = 0;
        for(int j=0; j<=i; j++) {
            sum += *tSigma++ * (tData[j] - tMean[j]); // xx[j] is always calculated since j <= i
        }
        discrim += sum * sum;
    }
    REAL d;
	REAL mydim = (REAL)iD;
    if (isLogScaled>0) {
	  d = log(tP)-0.5 * (discrim + tLogDet + (LOG_2_PI * mydim));
    } else {
	  d = tP * exp(-0.5 * (discrim + tLogDet + (LOG_2_PI*mydim)));
    }
    #if defined(TWISTED_DENSITY)
        result_trans[thidx * DATA_IN_BLOCK + thidy] = d;
        __syncthreads();
    #endif


    if (datumIndex < iN & densityIndex < iTJ) {
        #if defined(TWISTED_DENSITY)
            outPDF[pdfIndex] = result_trans[thidx + thidy * DENSITIES_IN_BLOCK];
        #else

            outPDF[pdfIndex] = d;
        #endif
    }
}

__device__ float compute_pdf(float* data, float* params, int iD) {
  unsigned int LOGDET_OFFSET = iD * (iD + 3) / 2;
  float* mean = params;
  float* sigma = params + iD;
  float mult = params[LOGDET_OFFSET];
  float logdet = params[LOGDET_OFFSET + 1];

  float discrim = 0;
  float sum;

  for (int i = 0; i < iD; ++i)
  {
   	sum = 0;
   	for(int j=0; j <= i; j++) {
   	  sum += *sigma++ * (data[j] - mean[j]);
   	}
   	discrim += sum * sum;
  }
  return log(mult) - 0.5 * (discrim + logdet + LOG_2_PI * (float) iD);
}

__global__ void mvnpdf_k(PMatrix data, PMatrix params, float* output) {
  unsigned int num_threads = blockDim.x * blockDim.y;
  unsigned int block_start = blockIdx.x * num_threads;

  // threads in row-major order, better perf
  unsigned int tid = threadIdx.y * blockDim.x + threadIdx.x;
  unsigned int obs_num = block_start + tid;

  extern __shared__ float sData[];

  float* sh_params = sData;
  float* sh_data = sData + params.stride;

  float* block_data = data.buf + block_start * data.stride;

  // coalesce data into shared memory in chunks
  unsigned int idx;
  for (int chunk = 0; chunk < data.stride; ++chunk)
  {
	idx = chunk * num_threads + tid;
	sh_data[idx] = block_data[idx];
  }
  __syncthreads();

  // read mean, cov, scalar, logdet into shared memory
  for (int chunk = 0; chunk < params.stride; chunk += num_threads)
  {
	if (chunk + tid < params.stride)
	  sh_params[chunk + tid] = params.buf[chunk + tid];
  }

  __syncthreads();

  float density = compute_pdf(sh_data + tid * data.stride,
							  sh_params, data.cols);

  if (obs_num < data.rows) {
	output[obs_num] = density;
  }
}

__global__ void mvnpdf_k2(const PMatrix data, const PMatrix params, float* output) {

  // coalesce data into shared memory in chunks
  const int num_threads = blockDim.x * blockDim.y;

  // threads in row-major order, better perf
  int tid = threadIdx.y * blockDim.x + threadIdx.x;

  // now compute your own pdf
  // need to coalesce back into global memory?
  int obs_num = blockDim.x * blockIdx.x + threadIdx.x;
  int param_index = blockIdx.y * blockDim.y + threadIdx.y;
  int result_idx = params.rows * obs_num + param_index;

  // set up shared data
  extern __shared__ float sData[];

  float* sh_params = sData; // store parameters
  float* sh_data = sh_params + blockDim.y * params.stride; // store data
  float* sh_result = sh_data + blockDim.x * data.stride; // store pdfs

  int idx;
  const int data_start = blockDim.x * blockIdx.x * data.stride;
  const int data_total = data.rows * data.stride;
  for (int chunk = data_start;
	   chunk < data_start + blockDim.x * data.stride;
	   chunk += num_threads)
  {
	idx = chunk + tid;
	if (idx < data_total)
	  sh_data[idx - data_start] = data.buf[idx];
  }

  const int params_start = blockDim.y * blockIdx.y * params.stride;
  const int params_total = params.rows * params.stride;
  for (int chunk = params_start;
	   chunk < params_start + blockDim.y * params.stride;
	   chunk += num_threads)
  {
	idx = chunk + tid;
	if (idx < params_total)
	  sh_params[idx - params_start] = params.buf[idx];
  }

  __syncthreads();

  int sh_idx = threadIdx.y * blockDim.x + threadIdx.x;
  if (obs_num < data.rows & param_index < params.rows) {
	float d = compute_pdf(sh_data + threadIdx.x * data.stride,
						  sh_params + threadIdx.y * params.stride,
						  data.cols);
	sh_result[sh_idx] = d;
  }
  __syncthreads();

  // // write out in other order to coalesce
  // // transpose! to get it to coalesce
  // const int result_idx = param_index * data.rows + obs_num;

  // // thread number in column-major order
  // tid = threadIdx.x * blockDim.y + threadIdx.y;
  // obs_num = blockDim.x * blockIdx.x + tid / blockDim.y;
  // param_index = blockIdx.y * blockDim.y + tid % blockDim.y;
  // const int result_idx = params.rows * obs_num + tid % blockDim.y;

  if (obs_num < data.rows & param_index < params.rows) {
	// sh_idx = tid;
	output[result_idx] = sh_result[sh_idx];
  }
}

cudaError_t invoke_mvnpdf2(PMatrix data, PMatrix params, float* d_pdf) {

  int block_size = 256;

  dim3 gridPDF((data.rows + block_size - 1) / block_size, 1);

  dim3 blockPDF(block_size, 1);
  int sharedMemSize = SIZE_REAL * (params.stride + data.stride * block_size);

  printf("sharedMemSize: %d\n", sharedMemSize);
  printf("max shared: %d\n", smem_size());

  mvnpdf_k<<<gridPDF,blockPDF,sharedMemSize>>>(data, params, d_pdf);

  return cudaSuccess;
}

cudaError_t invoke_mvnpdf3(PMatrix data, PMatrix params, float* d_pdf) {
  // Need to automatically tune block / grid layout to maximize shared memory
  // usage and coalescence, reduce wasted threads!
  TuningInfo tune_info;
  get_tuned_layout(&tune_info, &data, &params);

  // Now set up grid layout / block size
  int grid_x = get_boxes(data.rows, tune_info.data_per_block);
  int grid_y = get_boxes(params.rows, tune_info.params_per_block);
  dim3 gridPDF(grid_x, grid_y);

  dim3 blockPDF(tune_info.data_per_block,
				tune_info.params_per_block);
  int sharedMemSize = compute_shmem(&data, &params,
									tune_info.params_per_block,
									tune_info.data_per_block);

  printf("number params: %d, number data points: %d\n",
		 tune_info.params_per_block, tune_info.data_per_block);
  printf("sharedMemSize: %d\n", sharedMemSize);
  printf("block: %d x %d, grid: %d x %d\n", blockPDF.x, blockPDF.y,
		 gridPDF.x, gridPDF.y);
  printf("nparams: %d\n", params.rows);

  mvnpdf_k2<<<gridPDF,blockPDF,sharedMemSize>>>(data, params, d_pdf);
  return cudaSuccess;
}

void mvnpdf2(float* h_data, /** Data-vector; padded */
			 float* h_params, /** Density info; already padded */
			 float* h_pdf, /** Resultant PDF */
			 int data_dim,
			 int total_obs,
			 int nparams, // multiple sets of parameters
			 int param_stride, // with padding
			 int data_stride // with padding
  ) {

  float* d_data;
  float* d_params;
  float* d_pdf;
  cudaError_t error;

  PMatrix pdata, pparams;
  CATCH_ERR(cudaMalloc(&d_pdf, total_obs * nparams * sizeof(float)));
  cudaMemset((void*) d_pdf, 1, total_obs * nparams * sizeof(float));

  CATCH_ERR(cudaMalloc(&d_data, data_stride * total_obs * sizeof(float)));
  CATCH_ERR(cudaMalloc(&d_params, param_stride * nparams * sizeof(float)));

  h_to_d(h_data, d_data, total_obs * data_stride);
  h_to_d(h_params, d_params, nparams * param_stride);

  PMatrix_init(&pdata, d_data, total_obs, data_dim, data_stride);
  PMatrix_init(&pparams, d_params, nparams,
			   data_dim * (data_dim + 3) / 2 + 2, param_stride);

  invoke_mvnpdf3(pdata, pparams, d_pdf);
  d_to_h(d_pdf, h_pdf, total_obs * nparams);

  cudaFree(d_data);
  cudaFree(d_params);
  cudaFree(d_pdf);
}


cudaError_t gpuMvNormalPDF(
                    REAL* hData, /** Data-vector; padded */
                    REAL* hParams, /** Density info; already padded */
                    REAL* hPDF, /** Resultant PDF */
                    int iD,
                    int iN,
                    int iTJ,
					int PACK_DIM,
					int DIM
                    ) {

  float* dData;
  float* dParams;
  float* dPDF;

  cudaMalloc(&dData, DIM * iN * sizeof(float));
  cudaMalloc(&dParams, PACK_DIM * sizeof(float));
  cudaMalloc(&dPDF, iN * sizeof(float));

  h_to_d(hData, dData, iN);
  h_to_d(hParams, dParams, PACK_DIM);

  dim3 gridPDF(iN/DATA_IN_BLOCK, iTJ/DENSITIES_IN_BLOCK);
  if (iN % DATA_IN_BLOCK != 0)
	gridPDF.x += 1;
  if (iTJ % DENSITIES_IN_BLOCK != 0)
	gridPDF.y += 1;

  dim3 blockPDF(DATA_IN_BLOCK,DENSITIES_IN_BLOCK);
#if defined(TWISTED_DENSITY)
  int sharedMemSize = (DENSITIES_IN_BLOCK * PACK_DIM + DATA_IN_BLOCK * DIM \
					   + DENSITIES_IN_BLOCK*DATA_IN_BLOCK) * SIZE_REAL;
#else
  int sharedMemSize = (DENSITIES_IN_BLOCK * PACK_DIM + DATA_IN_BLOCK * DIM) * SIZE_REAL;
#endif
#if defined(LOGPDF)
  mvNormalPDF<<<gridPDF,blockPDF,sharedMemSize>>>(dData, dParams, dPDF,iD, iN, iTJ,1);
#else
  mvNormalPDF<<<gridPDF,blockPDF,sharedMemSize>>>(dData, dParams, dPDF, iD, iN, iTJ,0);
#endif

  d_to_h(dPDF, hPDF, iN);

  cudaFree(dData);
  cudaFree(dParams);
  cudaFree(dPDF);

    return cudaSuccess;
}

void cpu_mvnormpdf(float* x, float* density, float * output, int D, int N, int T) {
    int LOGDET_OFFSET = D * (D + 3) / 2;
	int MEAN_CHD_DIM = D * (D + 3) / 2	+ 2;
	int PACK_DIM = 16;

	while (MEAN_CHD_DIM > PACK_DIM) {PACK_DIM += 16;}
	int DATA_PADDED_DIM = 8;
	while (D > DATA_PADDED_DIM) {DATA_PADDED_DIM += 8;}

    float* xx = (float*) malloc(D * sizeof(float));
    int obs, component;

    for (obs = 0; obs < N; obs++) {
        for (component = 0; component < T; component++) {
            float discrim;
            float* tData = x + obs * DATA_PADDED_DIM;
            float* tDensityInfo = density + component * PACK_DIM;
            float* tMean = tDensityInfo;			//do we need to unallocate shared/register variables?
            float* tSigma = tDensityInfo + D;
            float  tP = tDensityInfo[LOGDET_OFFSET];
            float  tLogDet = tDensityInfo[LOGDET_OFFSET+1];

            // Do density calculation
            discrim = 0;
            for(int i=0; i<D; i++) {
                float sum = 0;
                for(int j=0; j<=i; j++) {
				  // printf("%d %d %f %f %f\n", i, j, *tSigma, tData[j], tMean[j]);
				  sum += *tSigma * (tData[j] - tMean[j]); // xx[j] is always calculated since j <= i
				  tSigma++;
                }

                discrim += sum * sum;
            }

            float d = log(tP) - 0.5 * (discrim + tLogDet + (LOG_2_PI*(float) D));
			// printf("discrim: %f\n", discrim);
			// printf("tP: %f\n", tP);
			// printf("tLogDet: %f\n", tLogDet);
			// printf("d: %f\n", d);
			// printf("idx: %d\n", obs * T + component);
            output[obs * T + component] = d;
        }
    }
	free(xx);
}


#ifdef __cplusplus
}
#endif

#endif // _INCLUDED_MVNPDF
