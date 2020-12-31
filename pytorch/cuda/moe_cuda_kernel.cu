#include <torch/extension.h>
#include <torch/torch.h>
#include <cstdio>
#include <iostream>
#include <vector>


#include <cuda.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>                                                                                          
#include <helper_cuda.h> 

#include <mpi.h>

#include "timer.hh"

#include "cublas_wrapper.h"
#include "cuda_stream_manager.h"
#include "comm_manager.h"

#define CEIL(_x_,_y_) (((_x_)-1)/(_y_)+1)

// #define MOE_BREAKDOWN
// #define MOE_DEBUG_SCATTER

template <typename scalar_t>
__global__
void generate_ptr_offset_kernel(size_t n, const scalar_t* base, size_t stride,
		const int* offset, const scalar_t** ptrs) { 
	size_t idx = threadIdx.x + blockDim.x * blockIdx.x;
	if (idx < n) {
		ptrs[idx] = base + stride * offset[idx];
	}
}


template <typename scalar_t>
__global__
void batch_scatter_kernel(int wid, int* pos, 
		const scalar_t* inbuf, scalar_t* oubuf) { 
	inbuf += wid * blockIdx.x;
	oubuf += wid * pos[blockIdx.x];
	for (int i = threadIdx.x; i < wid; i += blockDim.x) {
		oubuf[i] = inbuf[i];
	}
}

template <typename scalar_t>
__global__
void batch_gather_kernel(int wid, int* pos, 
		const scalar_t* inbuf, scalar_t* oubuf) { 
	inbuf += wid * pos[blockIdx.x];
	oubuf += wid * blockIdx.x;
	for (int i = threadIdx.x; i < wid; i += blockDim.x) {
		oubuf[i] = inbuf[i];
	}
}


template <typename scalar_t>
void moe_cuda_forward_impl(
        const scalar_t* input,
        const int* d_gate,
        const scalar_t* weight1,
        const scalar_t* weight2,
        scalar_t* output,
        const size_t batch_size,
        const size_t in_feat,
        const size_t hidden_feat,
        const size_t out_feat,
        const size_t num_expert) {

    auto h = getCudaStreamManager(num_expert);
	auto cm = getCommManager();
	int tot_expert = num_expert * cm->size;

#ifdef MOE_BREAKDOWN
	timestamp(t_init);
#endif

	scalar_t *local_input_buf, *local_output_buf;

	checkCudaErrors(cudaMalloc(&local_input_buf, sizeof(scalar_t) * batch_size *
				in_feat));

#ifdef MOE_BREAKDOWN
	timestamp(t_malloc);
	fprintf(stderr, "Malloc time %.3lf us\n", getDuration(t_init, t_malloc) *
			1e6);
#endif

    int *gate = new int[batch_size];
	int *expert_count = new int[tot_expert], *expert_ptr = new int[tot_expert];
	memset(expert_count, 0, sizeof(int) * tot_expert);

	checkCudaErrors(cudaMemcpy(gate, d_gate, sizeof(int) * batch_size,
				cudaMemcpyDeviceToHost));

#ifdef MOE_BREAKDOWN
	timestamp(t_cpy);
	fprintf(stderr, "Copy time %.3lf us\n", getDuration(t_malloc, t_cpy) *
			1e6);
#endif

	for (int i = 0; i < batch_size; ++i) {
		++expert_count[gate[i]];
	}
	expert_ptr[0] = 0;
	for (int i = 1; i < tot_expert; ++i) {
		expert_ptr[i] = expert_ptr[i - 1] + expert_count[i - 1];
	}

	int *pos = new int[batch_size];
	int *d_pos;
	checkCudaErrors(cudaMalloc(&d_pos, sizeof(int) * batch_size));

	for (int i = 0; i < batch_size; ++i) {
		pos[i] = expert_ptr[gate[i]]++;
	}
	checkCudaErrors(cudaMemcpy(d_pos, pos, sizeof(int) * batch_size,
				cudaMemcpyHostToDevice));

	int *all_expert_count = new int[tot_expert];
	MPI_Alltoall(expert_count, num_expert, MPI_INT, 
			all_expert_count, num_expert, MPI_INT, MPI_COMM_WORLD);

	int *expert_n = new int[num_expert];
	int expert_sz = 0;
	for (int i = 0; i < num_expert; ++i) {
		expert_n[i] = 0;
		for (int j = 0; j < cm->size; ++j) {
			expert_n[i] += all_expert_count[j * num_expert + i];
		}
		expert_sz += expert_n[i];
	}
	scalar_t *input_buf, *hidden_buf, *output_buf;
	checkCudaErrors(cudaMalloc(&hidden_buf, 
				sizeof(scalar_t) * expert_sz * hidden_feat));

#ifdef MOE_DEBUG
	for (int i = 0; i < tot_expert; ++i) {
		fprintf(stderr, "%d %d %d\n", cm->rank, i, expert_count[i]);
	}
	if (cm->rank == 0) {
		for (int i = 0; i < tot_expert; ++i) {
			fprintf(stderr, "%d ",all_expert_count[i]);
		}
		fprintf(stderr, "\n");
	}
#endif

#ifdef MOE_BREAKDOWN
	timestamp(t_expert);
	fprintf(stderr, "Expert asn time %.3lf us\n", getDuration(t_cpy, t_expert) *
			1e6);
#endif

	batch_scatter_kernel<scalar_t>
		<<<batch_size, 256, 0, h->getStream(0)>>>(in_feat, d_pos, input,
				local_input_buf); 
	h->sync(0);

	if (cm->rank > 1) {
		checkCudaErrors(cudaMalloc(&input_buf, 
					sizeof(scalar_t) * expert_sz * in_feat));
		checkCudaErrors(cudaMalloc(&output_buf, 
					sizeof(scalar_t) * expert_sz * out_feat));
		ncclGroupStart();
		int recv_ptr = 0;
		for (int i = 0; i < num_expert; ++i) {
			for (int j = 0; j < cm->size; ++j) {
				int send_id = i + j * num_expert;
				if (expert_count[send_id]) {
					ncclSend(local_input_buf + expert_ptr[send_id] * in_feat, 
							expert_count[send_id] * in_feat * sizeof(scalar_t),
							ncclChar, 
							j,
							cm->ncclcomm,
							h->getStream(0));
				}
				int recv_id = i * cm->size + j;
				if (all_expert_count[recv_id]) {
					ncclRecv(input_buf + recv_ptr * in_feat,
							all_expert_count[recv_id] * in_feat * sizeof(scalar_t),
							ncclChar,
							j,
							cm->ncclcomm,
							h->getStream(0));
					recv_ptr += all_expert_count[recv_id];
				}
			}
		}
		ncclGroupEnd();
	} else {
		input_buf = local_input_buf;
	}

#ifdef MOE_BREAKDOWN
	h->sync();
	timestamp(t_scatter);
	fprintf(stderr, "Scatter time %.3lf us\n", getDuration(t_expert, t_scatter) *
			1e6);
#endif

	scalar_t alpha = 1, beta = 0; 

	for (int i = 0, ptr = 0; i < num_expert; ++i) {
		if (expert_n[i] == 0) {
			continue;
		}
#ifdef MOE_DEBUG_SCATTER
		fprintf(stderr, "gemm %d sz %d\n", i, expert_n[i]);
		fprintf(stderr, "GeMM %d x %d x %d\n", out_feat, expert_n[i],
				in_feat);
#endif
		// Use T(B) x T(A) = T(C) to produce row-major C
		checkCudaErrors(cublasXgemm(h->getHandle(i),
				CUBLAS_OP_T,
				CUBLAS_OP_N,
				hidden_feat, expert_n[i], in_feat,
				&alpha,
				weight1 + i * in_feat * hidden_feat, in_feat,
				input_buf + ptr * in_feat, in_feat,
				&beta,
				hidden_buf + hidden_feat * ptr, hidden_feat
				));

		checkCudaErrors(cublasXgemm(h->getHandle(i),
				CUBLAS_OP_T,
				CUBLAS_OP_N,
				out_feat, expert_n[i], hidden_feat,
				&alpha,
				weight2 + i * hidden_feat * out_feat, hidden_feat,
				hidden_buf + hidden_feat * ptr, hidden_feat,
				&beta,
				output_buf + out_feat * ptr, out_feat
				));

		ptr += expert_n[i];
	}
	h->sync();

#ifdef MOE_BREAKDOWN
	timestamp(t_mm);
	fprintf(stderr, "GeMM time %.3lf us\n", getDuration(t_scatter, t_mm) *
			1e6);
#endif

	if (cm->rank > 1) {
		checkCudaErrors(cudaMalloc(&local_output_buf, 
					sizeof(scalar_t) * batch_size * out_feat));
		ncclGroupStart();
		int send_ptr = 0;
		for (int i = 0; i < num_expert; ++i) {
			for (int j = 0; j < cm->size; ++j) {
				int recv_id = i + j * num_expert;
				if (expert_count[recv_id]) {
					ncclRecv(local_output_buf + expert_ptr[recv_id] * in_feat, 
							expert_count[recv_id] * in_feat * sizeof(scalar_t),
							ncclChar, 
							j,
							cm->ncclcomm,
							h->getStream(0));
				}
				int send_id = i * cm->size + j;
				if (all_expert_count[send_id]) {
					ncclSend(output_buf + send_ptr * in_feat,
							all_expert_count[send_id] * in_feat * sizeof(scalar_t),
							ncclChar,
							j,
							cm->ncclcomm,
							h->getStream(0));
					send_ptr += all_expert_count[send_id];
				}
			}
		}
		ncclGroupEnd();
	} else {
		local_output_buf = output_buf;
	}

	batch_gather_kernel<scalar_t>
		<<<batch_size, 256, 0, h->getStream(0)>>>(out_feat, d_pos, 
				local_output_buf, output); 
	h->sync(0);

#ifdef MOE_BREAKDOWN
	timestamp(t_gather);
	fprintf(stderr, "Gather time %.3lf us\n", getDuration(t_mm, t_gather) *
			1e6);
	fprintf(stderr, "Overall time %.3lf us\n", getDuration(t_init, t_gather) *
			1e6);
#endif

	cudaFree(input_buf);
	cudaFree(hidden_buf);
	cudaFree(output_buf);
	if (cm->rank > 1) {
		cudaFree(local_input_buf);
		cudaFree(local_output_buf);
	}
	cudaFree(d_pos);
	delete [] pos;
	delete [] gate;
}

template <typename scalar_t>
void moe_cuda_grad_weight(
        const scalar_t* input,
        const int* gate,
        const scalar_t* grad_output,
        scalar_t* grad_weight, // [num_expert x out_feat x in_feat]
        const size_t batch_size,
        const size_t in_feat,
        const size_t out_feat,
        const size_t num_expert) {

    auto h = getCudaStreamManager(num_expert);
    
    int* gate_host = new int[batch_size];
    scalar_t alpha = 1, beta = 1;
    checkCudaErrors(cudaMemcpy(gate_host, gate, batch_size * sizeof(int), cudaMemcpyDeviceToHost));
    for (size_t i=0; i<batch_size; ++i) {
        checkCudaErrors(cublasSetStream(h->handles[0], *(h->streams + gate_host[i])));
        checkCudaErrors(cublasXgemm(h->handles[0],
            CUBLAS_OP_N, 
            CUBLAS_OP_T,
            out_feat, 
            in_feat, 
            1,
            &alpha,
            grad_output + i * out_feat,
            out_feat,
            input + i * in_feat,
            in_feat,
            &beta,
            grad_weight + gate_host[i] * out_feat * in_feat,
            out_feat));
    }
    for (size_t i=0; i<num_expert; ++i) {
        checkCudaErrors(cudaStreamSynchronize(*(h->streams + i)));
    }
    delete[] gate_host;
}

std::vector<torch::Tensor> moe_cuda_forward(
        torch::Tensor input,
        torch::Tensor gate,
        torch::Tensor weight1,
        torch::Tensor weight2
		) {
    const auto batch_size = input.size(0);
    const auto num_expert = weight1.size(0);
    const auto out_feat = weight2.size(1);
	const auto hidden_feat = weight1.size(1);
    const auto in_feat = weight1.size(2);
            
#ifdef MOE_DEBUG
    printf("[forward] b=%ld, expert=%ld, in_feat (d_model)=%ld, hidden_feat = %ld,out_feat (d_ffn)=%ld\n", batch_size, num_expert, in_feat, hidden_feat, out_feat);
#endif
    auto output = input.new_zeros({batch_size, out_feat});
    
    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_forward_cuda", ([&] {
                moe_cuda_forward_impl<scalar_t>(
                    input.data_ptr<scalar_t>(),
                    gate.data_ptr<int>(),
                    weight1.data_ptr<scalar_t>(),
                    weight2.data_ptr<scalar_t>(),
                    output.data_ptr<scalar_t>(),
                    batch_size,
                    in_feat,
					hidden_feat,
                    out_feat,
                    num_expert
                );
    }));
    
    return {output, };           
}

std::vector<torch::Tensor> moe_cuda_backward(
    torch::Tensor grad_output, // [batch_size x out_feat]
    torch::Tensor input, // [batch_size x out_feat]
    torch::Tensor gate,  // [batch_size]
    torch::Tensor weight // [num_expert x out_feat x in_feat]
) {
    const auto batch_size = input.size(0);
    const auto num_expert = weight.size(0);
    const auto out_feat = weight.size(1);
    const auto in_feat = weight.size(2);
#ifdef MOE_DEBUG
    printf("[backward] b=%ld, expert=%ld, in_feat (d_model)=%ld, out_feat (d_ffn)=%ld\n", batch_size, num_expert, in_feat, out_feat);
#endif

    auto grad_input = grad_output.new_zeros({batch_size, in_feat});  // batch_size x in_feat
    auto grad_weight = grad_output.new_zeros({num_expert, out_feat, in_feat}); // num_expert x out_feat x in_feat

    // grad_input is easy to compute, exactly the same as forward
	/* TODO: Backward currently brokenn
    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_cuda_backward", ([&] {
        moe_cuda_forward_impl<scalar_t>(
            grad_output.data_ptr<scalar_t>(),
            gate.data_ptr<int>(),
            weight.data_ptr<scalar_t>(),
            grad_input.data_ptr<scalar_t>(),
            batch_size,
            out_feat,
            in_feat,
            num_expert,
            CUBLAS_OP_N
        );
    }));
	*/

    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_cuda_backward", ([&] {
        moe_cuda_grad_weight<scalar_t>(
            input.data_ptr<scalar_t>(),
            gate.data_ptr<int>(),
            grad_output.data_ptr<scalar_t>(),
            grad_weight.data_ptr<scalar_t>(),
            batch_size,
            in_feat,
            out_feat,
            num_expert
        );
    }));

    return {grad_input, grad_weight};
}


/*
int main() {
    typedef float data_t;
    size_t batch_size = 4096;
    size_t top_k = 2;
    size_t num_expert = 128;
    size_t in_feat = 1024;
    size_t out_feat = 4096;
	data_t *input, *weight;
	data_t *output;
	size_t *gate;

	checkCudaErrors(cudaMalloc(&input, batch_size * in_feat * sizeof(data_t)));
	checkCudaErrors(cudaMalloc(&weight, num_expert * in_feat * out_feat * sizeof(data_t)));	
	checkCudaErrors(cudaMalloc(&output, batch_size * top_k * out_feat * sizeof(data_t)));
    checkCudaErrors(cudaMalloc(&gate, batch_size * top_k * sizeof(size_t)));
    
    size_t nt = 16;
    double tsum = 0, tmax = 0;

    size_t *gate_host = new size_t[batch_size * top_k];
    for (size_t i=0; i<batch_size * top_k; ++i) {
        gate_host[i] = rand() % num_expert;
    } 
    checkCudaErrors(cudaMemcpy(gate, gate_host, batch_size * top_k * sizeof(size_t), cudaMemcpyHostToDevice));

    moe_first_linear_cuda_forward<data_t>(input, gate, weight, output, batch_size, top_k, in_feat, out_feat);
    
    for (size_t i=0; i<nt; ++i) {
        timestamp(start);
		moe_first_linear_cuda_forward<data_t>(input, gate, weight, output, batch_size, top_k, in_feat, out_feat);
		timestamp(end);
		auto t = getDuration(start, end);
		tsum += t;
		if (t > tmax) tmax = t;
    }
    printf("Mean %.3lf us, max %.3lf us\n", tsum / nt * 1e6, tmax * 1e6);
	double tflops = (double)batch_size * top_k * in_feat * out_feat * nt * 2e-12 / tsum;
	printf("%.3lf TFLOPs\n", tflops);
}
*/
