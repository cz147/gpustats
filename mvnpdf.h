#ifndef __MVNPDF_H__
#define __MVNPDF_H__

#include <stdio.h>
#include <cuda_runtime_api.h>

#include "common.h"

void mvnpdf2(float* h_data, /** Data-vector; padded */
			 float* h_params, /** Density info; already padded */
			 float* h_pdf, /** Resultant PDF */
			 int data_dim,
			 int total_obs,
			 int param_stride, // with padding
			 int data_stride // with padding
  );

void cpu_mvnormpdf(float* x, float* density, float * output, int D,
				   int N, int T);

void testf(float* ptr, int n);

#endif