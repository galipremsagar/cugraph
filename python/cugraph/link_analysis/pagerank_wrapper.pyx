# Copyright (c) 2019-2021, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cugraph.link_analysis.pagerank cimport call_pagerank
from cugraph.structure.graph_utilities cimport *
from libcpp cimport bool
from libc.stdint cimport uintptr_t
from cugraph.structure import graph_primtypes_wrapper
import cudf
import numpy as np


def pagerank(input_graph, alpha=0.85, personalization=None, max_iter=100, tol=1.0e-5, nstart=None):
    """
    Call pagerank
    """

    cdef unique_ptr[handle_t] handle_ptr
    handle_ptr.reset(new handle_t())
    handle_ = handle_ptr.get();

    [src, dst] = graph_primtypes_wrapper.datatype_cast([input_graph.edgelist.edgelist_df['src'], input_graph.edgelist.edgelist_df['dst']], [np.int32])
    weights = None
    if input_graph.edgelist.weights:
        [weights] = graph_primtypes_wrapper.datatype_cast([input_graph.edgelist.edgelist_df['weights']], [np.float32, np.float64])

    num_verts = input_graph.number_of_vertices()
    num_edges = input_graph.number_of_edges(directed_edges=True)
    # FIXME: needs to be edge_t type not int
    cdef int num_local_edges = len(src)

    df = cudf.DataFrame()
    df['vertex'] = cudf.Series(np.arange(num_verts, dtype=np.int32))
    df['pagerank'] = cudf.Series(np.zeros(num_verts, dtype=np.float32))

    cdef bool has_guess = <bool> 0
    if nstart is not None:
        if len(nstart) != num_verts:
            raise ValueError('nstart must have initial guess for all vertices')
        df['pagerank'][nstart['vertex']] = nstart['values']
        has_guess = <bool> 1

    cdef uintptr_t c_identifier = df['vertex'].__cuda_array_interface__['data'][0];
    cdef uintptr_t c_pagerank_val = df['pagerank'].__cuda_array_interface__['data'][0];

    cdef uintptr_t c_pers_vtx = <uintptr_t>NULL
    cdef uintptr_t c_pers_val = <uintptr_t>NULL
    cdef int sz = 0

    cdef uintptr_t c_src_vertices = src.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_dst_vertices = dst.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_edge_weights = <uintptr_t>NULL
    
    personalization_id_series = None

    if weights is not None:
        c_edge_weights = weights.__cuda_array_interface__['data'][0]
        weight_t = weights.dtype
        is_weighted = True
    else:
        weight_t = np.dtype("float32")
        is_weighted = False

    is_symmetric = not input_graph.is_directed()

    # FIXME: Offsets and indices are currently hardcoded to int, but this may
    #        not be acceptable in the future.
    numberTypeMap = {np.dtype("int32") : <int>numberTypeEnum.int32Type,
                     np.dtype("int64") : <int>numberTypeEnum.int64Type,
                     np.dtype("float32") : <int>numberTypeEnum.floatType,
                     np.dtype("double") : <int>numberTypeEnum.doubleType}

    if personalization is not None:
        sz = personalization['vertex'].shape[0]
        personalization['vertex'] = personalization['vertex'].astype(np.int32)
        personalization['values'] = personalization['values'].astype(df['pagerank'].dtype)
        c_pers_vtx = personalization['vertex'].__cuda_array_interface__['data'][0]
        c_pers_val = personalization['values'].__cuda_array_interface__['data'][0]

    cdef graph_container_t graph_container
    populate_graph_container(graph_container,
                             handle_[0],
                             <void*>c_src_vertices, <void*>c_dst_vertices, <void*>c_edge_weights,
                             <void*>NULL,
                             <numberTypeEnum>(<int>(numberTypeEnum.int32Type)),
                             <numberTypeEnum>(<int>(numberTypeEnum.int32Type)),
                             <numberTypeEnum>(<int>(numberTypeMap[weight_t])),
                             num_local_edges,
                             num_verts, num_edges,
                             False,
                             is_weighted,
                             is_symmetric,
                             True,
                             False)

    if (df['pagerank'].dtype == np.float32):
        call_pagerank[int, float](handle_[0], graph_container,
                                  <int*>c_identifier,
                                  <float*> c_pagerank_val, sz,
                                  <int*> c_pers_vtx, <float*> c_pers_val,
                                  <float> alpha, <float> tol,
                                  <int> max_iter, has_guess)

    else:
        call_pagerank[int, double](handle_[0], graph_container,
                                   <int*>c_identifier,
                                   <double*> c_pagerank_val, sz,
                                   <int*> c_pers_vtx, <double*> c_pers_val,
                                   <float> alpha, <float> tol,
                                   <int> max_iter, has_guess)
    return df
