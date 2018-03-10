/**
 * @brief
 * @author Oded Green                                                       <br>
 *   Georgia Institute of Technology, Computational Science and Engineering <br>                   <br>
 *   ogreen@gatech.edu
 * @date August, 2017
 * @version v2
 *
 * @copyright Copyright © 2017 Hornet. All rights reserved.
 *
 * @license{<blockquote>
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * * Neither the name of the copyright holder nor the names of its
 *   contributors may be used to endorse or promote products derived from
 *   this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 * </blockquote>}
 *
 * @file
 */
#include "Static/PageRank/PageRank.cuh"
#include "PageRankOperators.cuh"

#include <cub.cuh>

namespace hornet_alg {

StaticPageRank::StaticPageRank(HornetGPU& hornet,
                               int  iteration_max,
                               pr_t threshold,
                               pr_t damp) :
                                    StaticAlgorithm(hornet),
                                    load_balacing(hornet) {
    setInputParameters(iteration_max, threshold, damp);
	hd_prdata().nV = hornet.nV();
	gpu::allocate(hd_prdata().prev_pr,  hornet.nV() + 1);
	gpu::allocate(hd_prdata().curr_pr,  hornet.nV() + 1);
	gpu::allocate(hd_prdata().abs_diff, hornet.nV() + 1);
	gpu::allocate(hd_prdata().contri,   hornet.nV() + 1);
	gpu::allocate(hd_prdata().reduction_out, 1);
	reset();
}

StaticPageRank::~StaticPageRank() {
    release();
}

void StaticPageRank::release() {
    gpu::free(hd_prdata().prev_pr);
	gpu::free(hd_prdata().curr_pr);
	gpu::free(hd_prdata().abs_diff);
    gpu::free(hd_prdata().contri);
	gpu::free(hd_prdata().reduction_out);
    host::free(host_page_rank);
}

void StaticPageRank::reset(){
	hd_prdata().iteration = 0;
}

void StaticPageRank::setInputParameters(int  iteration_max,
                                        pr_t threshold,
                                        pr_t damp) {
	hd_prdata().iteration_max   = iteration_max;
	hd_prdata().threshold       = threshold;
	hd_prdata().damp            = damp;
	hd_prdata().normalized_damp = (1.0f - hd_prdata().damp) /
                                  static_cast<float>(hornet.nV());
}

void StaticPageRank::run() {
	forAllnumV(hornet, InitOperator { hd_prdata });
	hd_prdata().iteration = 0;

	pr_t h_out = hd_prdata().threshold + 1;

	while(hd_prdata().iteration < hd_prdata().iteration_max &&
          h_out > hd_prdata().threshold) {

		forAllnumV(hornet, ResetCurr { hd_prdata });
		forAllVertices(hornet, ComputeContribuitionPerVertex { hd_prdata });
		forAllEdges(hornet, AddContribuitionsUndirected { hd_prdata },
                    load_balacing);
		//forAllEdges(hornet, AddContribuitions { hd_prdata }, load_balacing);
		forAllnumV(hornet, DampAndDiffAndCopy { hd_prdata });

		forAllnumV(hornet, Sum { hd_prdata });
		hd_prdata.sync();

        host::copyFromDevice(hd_prdata().reduction_out, h_out);
		hd_prdata().iteration++;
	}
}

void StaticPageRank::printRankings() {
    pr_t*  d_scores, *h_scores;
    vid_t* d_ids, *h_ids;
    gpu::allocate(d_scores,  hornet.nV());
    gpu::allocate(d_ids,     hornet.nV());
    host::allocate(h_scores, hornet.nV());
    host::allocate(h_ids,    hornet.nV());

    gpu::copyToDevice(hd_prdata().curr_pr, hornet.nV(), d_scores);
	forAllnumV(hornet, SetIds { d_ids });

    pr_t*  d_scores_out;
    vid_t* d_ids_out;
    gpu::allocate(d_scores_out,  hornet.nV());
    gpu::allocate(d_ids_out,     hornet.nV());

    void *d_temp_storage = NULL;
    size_t temp_storage_bytes = 0;

    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
          d_ids, d_ids_out, d_scores, d_scores_out, hornet.nV());

    cudaMalloc(&d_temp_storage, temp_storage_bytes);

    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
          d_scores, d_scores_out, d_ids, d_ids_out, hornet.nV());

#if 1
    host::copyFromDevice(d_ids_out, hornet.nV(), h_ids);
    host::copyFromDevice(d_scores_out, hornet.nV(), h_scores);

        for (int i = 1; i < 11; i++)
        std::cout << "Pr[" << h_ids[hornet.nV()-i] << "]:= " <<  h_scores[hornet.nV()-i] << "\n";
#else
    host::copyFromDevice(d_scores, hornet.nV(), h_scores);
    host::copyFromDevice(d_ids,    hornet.nV(), h_ids);

	for (int i = 0; i < 10; i++)
        std::cout << "Pr[" << h_ids[i] << "]:= " <<  h_scores[i] << "\n";
#endif
    std::cout << std::endl;
	forAllnumV(hornet, ResetCurr { hd_prdata });
	forAllnumV(hornet, SumPr     { hd_prdata });

	pr_t h_out;
    host::copyFromDevice(hd_prdata().reduction_out, h_out);
	std::cout << "              " << std::setprecision(9) << h_out << std::endl;

	gpu::free(d_scores);
	gpu::free(d_ids);
	host::free(h_scores);
	host::free(h_ids);
}

const pr_t* StaticPageRank::get_page_rank_score_host() {
    host::allocate(host_page_rank, hornet.nV());
    host::copyFromDevice(hd_prdata().curr_pr, hornet.nV(), host_page_rank);
    return host_page_rank;
}

int StaticPageRank::get_iteration_count() {
	return hd_prdata().iteration;
}

bool StaticPageRank::validate() {
	return true;//?????????
}

}// hornet_alg namespace
