/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cugraph/experimental/detail/graph_utils.cuh>
#include <cugraph/experimental/graph_view.hpp>
#include <cugraph/partition_manager.hpp>
#include <cugraph/patterns/copy_v_transform_reduce_in_out_nbr.cuh>
#include <cugraph/utilities/error.hpp>
#include <cugraph/utilities/host_scalar_comm.cuh>

#include <raft/cudart_utils.h>
#include <rmm/thrust_rmm_allocator.h>
#include <raft/handle.hpp>
#include <rmm/device_scalar.hpp>

#include <thrust/count.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/sort.h>

#include <algorithm>
#include <cstdint>
#include <type_traits>
#include <vector>

namespace cugraph {
namespace experimental {

namespace {

// can't use lambda due to nvcc limitations (The enclosing parent function ("graph_view_t") for an
// extended __device__ lambda must allow its address to be taken)
template <typename vertex_t>
struct out_of_range_t {
  vertex_t min{};
  vertex_t max{};

  __device__ bool operator()(vertex_t v) { return (v < min) || (v >= max); }
};

template <typename vertex_t, typename edge_t>
std::vector<edge_t> update_adj_matrix_partition_edge_counts(
  std::vector<edge_t const*> const& adj_matrix_partition_offsets,
  partition_t<vertex_t> const& partition,
  cudaStream_t stream)
{
  std::vector<edge_t> adj_matrix_partition_edge_counts(partition.get_number_of_matrix_partitions(),
                                                       0);
  for (size_t i = 0; i < adj_matrix_partition_offsets.size(); ++i) {
    vertex_t major_first{};
    vertex_t major_last{};
    std::tie(major_first, major_last) = partition.get_matrix_partition_major_range(i);
    raft::update_host(&(adj_matrix_partition_edge_counts[i]),
                      adj_matrix_partition_offsets[i] + (major_last - major_first),
                      1,
                      stream);
  }
  CUDA_TRY(cudaStreamSynchronize(stream));
  return adj_matrix_partition_edge_counts;
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<edge_t> compute_minor_degrees(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const& graph_view)
{
  rmm::device_uvector<edge_t> minor_degrees(graph_view.get_number_of_local_vertices(),
                                            handle.get_stream());
  if (store_transposed) {
    copy_v_transform_reduce_out_nbr(
      handle,
      graph_view,
      thrust::make_constant_iterator(0) /* dummy */,
      thrust::make_constant_iterator(0) /* dummy */,
      [] __device__(vertex_t src, vertex_t dst, weight_t w, auto src_val, auto dst_val) {
        return edge_t{1};
      },
      edge_t{0},
      minor_degrees.data());
  } else {
    copy_v_transform_reduce_in_nbr(
      handle,
      graph_view,
      thrust::make_constant_iterator(0) /* dummy */,
      thrust::make_constant_iterator(0) /* dummy */,
      [] __device__(vertex_t src, vertex_t dst, weight_t w, auto src_val, auto dst_val) {
        return edge_t{1};
      },
      edge_t{0},
      minor_degrees.data());
  }

  return minor_degrees;
}

template <bool major,
          typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<weight_t> compute_weight_sums(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const& graph_view)
{
  rmm::device_uvector<weight_t> weight_sums(graph_view.get_number_of_local_vertices(),
                                            handle.get_stream());
  if (major == store_transposed) {
    copy_v_transform_reduce_in_nbr(
      handle,
      graph_view,
      thrust::make_constant_iterator(0) /* dummy */,
      thrust::make_constant_iterator(0) /* dummy */,
      [] __device__(vertex_t src, vertex_t dst, weight_t w, auto src_val, auto dst_val) {
        return w;
      },
      weight_t{0.0},
      weight_sums.data());
  } else {
    copy_v_transform_reduce_out_nbr(
      handle,
      graph_view,
      thrust::make_constant_iterator(0) /* dummy */,
      thrust::make_constant_iterator(0) /* dummy */,
      [] __device__(vertex_t src, vertex_t dst, weight_t w, auto src_val, auto dst_val) {
        return w;
      },
      weight_t{0.0},
      weight_sums.data());
  }

  return weight_sums;
}

}  // namespace

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  graph_view_t(raft::handle_t const& handle,
               std::vector<edge_t const*> const& adj_matrix_partition_offsets,
               std::vector<vertex_t const*> const& adj_matrix_partition_indices,
               std::vector<weight_t const*> const& adj_matrix_partition_weights,
               std::vector<vertex_t> const& adj_matrix_partition_segment_offsets,
               partition_t<vertex_t> const& partition,
               vertex_t number_of_vertices,
               edge_t number_of_edges,
               graph_properties_t properties,
               bool sorted_by_global_degree_within_vertex_partition,
               bool do_expensive_check)
  : detail::graph_base_t<vertex_t, edge_t, weight_t>(
      handle, number_of_vertices, number_of_edges, properties),
    adj_matrix_partition_offsets_(adj_matrix_partition_offsets),
    adj_matrix_partition_indices_(adj_matrix_partition_indices),
    adj_matrix_partition_weights_(adj_matrix_partition_weights),
    adj_matrix_partition_number_of_edges_(update_adj_matrix_partition_edge_counts(
      adj_matrix_partition_offsets, partition, handle.get_stream())),
    partition_(partition),
    adj_matrix_partition_segment_offsets_(adj_matrix_partition_segment_offsets)
{
  // cheap error checks

  auto const comm_size     = this->get_handle_ptr()->get_comms().get_size();
  auto const row_comm_size = this->get_handle_ptr()
                               ->get_subcomm(cugraph::partition_2d::key_naming_t().row_name())
                               .get_size();
  auto const col_comm_size = this->get_handle_ptr()
                               ->get_subcomm(cugraph::partition_2d::key_naming_t().col_name())
                               .get_size();

  CUGRAPH_EXPECTS(adj_matrix_partition_offsets.size() == adj_matrix_partition_indices.size(),
                  "Internal Error: adj_matrix_partition_offsets.size() and "
                  "adj_matrix_partition_indices.size() should coincide.");
  CUGRAPH_EXPECTS((adj_matrix_partition_weights.size() == adj_matrix_partition_offsets.size()) ||
                    (adj_matrix_partition_weights.size() == 0),
                  "Internal Error: adj_matrix_partition_weights.size() should coincide with "
                  "adj_matrix_partition_offsets.size() (if weighted) or 0 (if unweighted).");

  CUGRAPH_EXPECTS(adj_matrix_partition_offsets.size() == static_cast<size_t>(col_comm_size),
                  "Internal Error: erroneous adj_matrix_partition_offsets.size().");

  CUGRAPH_EXPECTS((sorted_by_global_degree_within_vertex_partition &&
                   (adj_matrix_partition_segment_offsets.size() ==
                    col_comm_size * (detail::num_segments_per_vertex_partition + 1))) ||
                    (!sorted_by_global_degree_within_vertex_partition &&
                     (adj_matrix_partition_segment_offsets.size() == 0)),
                  "Internal Error: adj_matrix_partition_segment_offsets.size() does not match "
                  "with sorted_by_global_degree_within_vertex_partition.");

  // optional expensive checks

  if (do_expensive_check) {
    auto default_stream = this->get_handle_ptr()->get_stream();

    auto const row_comm_rank = this->get_handle_ptr()
                                 ->get_subcomm(cugraph::partition_2d::key_naming_t().row_name())
                                 .get_rank();
    auto const col_comm_rank = this->get_handle_ptr()
                                 ->get_subcomm(cugraph::partition_2d::key_naming_t().col_name())
                                 .get_rank();

    edge_t number_of_local_edges_sum{};
    for (size_t i = 0; i < adj_matrix_partition_offsets.size(); ++i) {
      vertex_t major_first{};
      vertex_t major_last{};
      vertex_t minor_first{};
      vertex_t minor_last{};
      std::tie(major_first, major_last) = partition.get_matrix_partition_major_range(i);
      std::tie(minor_first, minor_last) = partition.get_matrix_partition_minor_range();
      CUGRAPH_EXPECTS(
        thrust::is_sorted(rmm::exec_policy(default_stream)->on(default_stream),
                          adj_matrix_partition_offsets[i],
                          adj_matrix_partition_offsets[i] + (major_last - major_first + 1)),
        "Internal Error: adj_matrix_partition_offsets[] is not sorted.");
      edge_t number_of_local_edges{};
      raft::update_host(&number_of_local_edges,
                        adj_matrix_partition_offsets[i] + (major_last - major_first),
                        1,
                        default_stream);
      CUDA_TRY(cudaStreamSynchronize(default_stream));
      number_of_local_edges_sum += number_of_local_edges;

      // better use thrust::any_of once https://github.com/thrust/thrust/issues/1016 is resolved
      CUGRAPH_EXPECTS(
        thrust::count_if(rmm::exec_policy(default_stream)->on(default_stream),
                         adj_matrix_partition_indices[i],
                         adj_matrix_partition_indices[i] + number_of_local_edges,
                         out_of_range_t<vertex_t>{minor_first, minor_last}) == 0,
        "Internal Error: adj_matrix_partition_indices[] have out-of-range vertex IDs.");
    }
    number_of_local_edges_sum = host_scalar_allreduce(
      this->get_handle_ptr()->get_comms(), number_of_local_edges_sum, default_stream);
    CUGRAPH_EXPECTS(number_of_local_edges_sum == this->get_number_of_edges(),
                    "Internal Error: the sum of local edges counts does not match with "
                    "number_of_local_edges.");

    if (sorted_by_global_degree_within_vertex_partition) {
      auto degrees = detail::compute_major_degrees(handle, adj_matrix_partition_offsets, partition);
      CUGRAPH_EXPECTS(
        thrust::is_sorted(rmm::exec_policy(default_stream)->on(default_stream),
                          degrees.begin(),
                          degrees.end(),
                          thrust::greater<edge_t>{}),
        "Invalid Invalid input argument: sorted_by_global_degree_within_vertex_partition is "
        "set to true, but degrees are not non-ascending.");

      for (int i = 0; i < col_comm_size; ++i) {
        CUGRAPH_EXPECTS(std::is_sorted(adj_matrix_partition_segment_offsets.begin() +
                                         (detail::num_segments_per_vertex_partition + 1) * i,
                                       adj_matrix_partition_segment_offsets.begin() +
                                         (detail::num_segments_per_vertex_partition + 1) * (i + 1)),
                        "Internal Error: erroneous adj_matrix_partition_segment_offsets.");
        CUGRAPH_EXPECTS(
          adj_matrix_partition_segment_offsets[(detail::num_segments_per_vertex_partition + 1) *
                                               i] == 0,
          "Internal Error: erroneous adj_matrix_partition_segment_offsets.");
        auto vertex_partition_idx = row_comm_size * i + row_comm_rank;
        CUGRAPH_EXPECTS(
          adj_matrix_partition_segment_offsets[(detail::num_segments_per_vertex_partition + 1) * i +
                                               detail::num_segments_per_vertex_partition] ==
            partition.get_vertex_partition_size(vertex_partition_idx),
          "Internal Error: erroneous adj_matrix_partition_segment_offsets.");
      }
    }

    CUGRAPH_EXPECTS(partition.get_vertex_partition_last(comm_size - 1) == number_of_vertices,
                    "Internal Error: vertex partition should cover [0, number_of_vertices).");

    // FIXME: check for symmetricity may better be implemetned with transpose().
    if (this->is_symmetric()) {}
    // FIXME: check for duplicate edges may better be implemented after deciding whether to sort
    // neighbor list or not.
    if (!this->is_multigraph()) {}
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
graph_view_t<vertex_t,
             edge_t,
             weight_t,
             store_transposed,
             multi_gpu,
             std::enable_if_t<!multi_gpu>>::graph_view_t(raft::handle_t const& handle,
                                                         edge_t const* offsets,
                                                         vertex_t const* indices,
                                                         weight_t const* weights,
                                                         std::vector<vertex_t> const&
                                                           segment_offsets,
                                                         vertex_t number_of_vertices,
                                                         edge_t number_of_edges,
                                                         graph_properties_t properties,
                                                         bool sorted_by_degree,
                                                         bool do_expensive_check)
  : detail::graph_base_t<vertex_t, edge_t, weight_t>(
      handle, number_of_vertices, number_of_edges, properties),
    offsets_(offsets),
    indices_(indices),
    weights_(weights),
    segment_offsets_(segment_offsets)
{
  // cheap error checks

  CUGRAPH_EXPECTS((sorted_by_degree &&
                   (segment_offsets.size() == (detail::num_segments_per_vertex_partition + 1))) ||
                    (!sorted_by_degree && (segment_offsets.size() == 0)),
                  "Internal Error: segment_offsets.size() does not match with sorted_by_degree.");

  // optional expensive checks

  if (do_expensive_check) {
    auto default_stream = this->get_handle_ptr()->get_stream();

    CUGRAPH_EXPECTS(thrust::is_sorted(rmm::exec_policy(default_stream)->on(default_stream),
                                      offsets,
                                      offsets + (this->get_number_of_vertices() + 1)),
                    "Internal Error: offsets is not sorted.");

    // better use thrust::any_of once https://github.com/thrust/thrust/issues/1016 is resolved
    CUGRAPH_EXPECTS(
      thrust::count_if(rmm::exec_policy(default_stream)->on(default_stream),
                       indices,
                       indices + this->get_number_of_edges(),
                       out_of_range_t<vertex_t>{0, this->get_number_of_vertices()}) == 0,
      "Internal Error: adj_matrix_partition_indices[] have out-of-range vertex IDs.");

    if (sorted_by_degree) {
      auto degree_first =
        thrust::make_transform_iterator(thrust::make_counting_iterator(vertex_t{0}),
                                        detail::degree_from_offsets_t<vertex_t, edge_t>{offsets});
      CUGRAPH_EXPECTS(thrust::is_sorted(rmm::exec_policy(default_stream)->on(default_stream),
                                        degree_first,
                                        degree_first + this->get_number_of_vertices(),
                                        thrust::greater<edge_t>{}),
                      "Internal Error: sorted_by_degree is set to true, but degrees are not "
                      "in ascending order.");

      CUGRAPH_EXPECTS(std::is_sorted(segment_offsets.begin(), segment_offsets.end()),
                      "Internal Error: erroneous segment_offsets.");
      CUGRAPH_EXPECTS(segment_offsets[0] == 0, "Invalid input argument segment_offsets.");
      CUGRAPH_EXPECTS(segment_offsets.back() == this->get_number_of_vertices(),
                      "Invalid input argument: segment_offsets.");
    }

    // FIXME: check for symmetricity may better be implemetned with transpose().
    if (this->is_symmetric()) {}
    // FIXME: check for duplicate edges may better be implemented after deciding whether to sort
    // neighbor list or not.
    if (!this->is_multigraph()) {}
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<edge_t>
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_in_degrees(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return detail::compute_major_degrees(
      handle, this->adj_matrix_partition_offsets_, this->partition_);
  } else {
    return compute_minor_degrees(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<edge_t>
graph_view_t<vertex_t,
             edge_t,
             weight_t,
             store_transposed,
             multi_gpu,
             std::enable_if_t<!multi_gpu>>::compute_in_degrees(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return detail::compute_major_degrees(
      handle, this->offsets_, this->get_number_of_local_vertices());
  } else {
    return compute_minor_degrees(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<edge_t>
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_out_degrees(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_minor_degrees(handle, *this);
  } else {
    return detail::compute_major_degrees(
      handle, this->adj_matrix_partition_offsets_, this->partition_);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<edge_t>
graph_view_t<vertex_t,
             edge_t,
             weight_t,
             store_transposed,
             multi_gpu,
             std::enable_if_t<!multi_gpu>>::compute_out_degrees(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_minor_degrees(handle, *this);
  } else {
    return detail::compute_major_degrees(
      handle, this->offsets_, this->get_number_of_local_vertices());
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<weight_t>
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_in_weight_sums(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_weight_sums<true>(handle, *this);
  } else {
    return compute_weight_sums<false>(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<weight_t> graph_view_t<
  vertex_t,
  edge_t,
  weight_t,
  store_transposed,
  multi_gpu,
  std::enable_if_t<!multi_gpu>>::compute_in_weight_sums(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_weight_sums<true>(handle, *this);
  } else {
    return compute_weight_sums<false>(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<weight_t>
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_out_weight_sums(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_weight_sums<false>(handle, *this);
  } else {
    return compute_weight_sums<true>(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<weight_t> graph_view_t<
  vertex_t,
  edge_t,
  weight_t,
  store_transposed,
  multi_gpu,
  std::enable_if_t<!multi_gpu>>::compute_out_weight_sums(raft::handle_t const& handle) const
{
  if (store_transposed) {
    return compute_weight_sums<false>(handle, *this);
  } else {
    return compute_weight_sums<true>(handle, *this);
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
edge_t
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_max_in_degree(raft::handle_t const& handle) const
{
  auto in_degrees = compute_in_degrees(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                in_degrees.begin(),
                                in_degrees.end());
  rmm::device_scalar<edge_t> ret(edge_t{0}, handle.get_stream());
  device_allreduce(handle.get_comms(),
                   it != in_degrees.end() ? it : ret.data(),
                   ret.data(),
                   1,
                   raft::comms::op_t::MAX,
                   handle.get_stream());
  return ret.value(handle.get_stream());
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
edge_t graph_view_t<vertex_t,
                    edge_t,
                    weight_t,
                    store_transposed,
                    multi_gpu,
                    std::enable_if_t<!multi_gpu>>::compute_max_in_degree(raft::handle_t const&
                                                                           handle) const
{
  auto in_degrees = compute_in_degrees(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                in_degrees.begin(),
                                in_degrees.end());
  edge_t ret{0};
  if (it != in_degrees.end()) { raft::update_host(&ret, it, 1, handle.get_stream()); }
  handle.get_stream_view().synchronize();
  return ret;
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
edge_t
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_max_out_degree(raft::handle_t const& handle) const
{
  auto out_degrees = compute_out_degrees(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                out_degrees.begin(),
                                out_degrees.end());
  rmm::device_scalar<edge_t> ret(edge_t{0}, handle.get_stream());
  device_allreduce(handle.get_comms(),
                   it != out_degrees.end() ? it : ret.data(),
                   ret.data(),
                   1,
                   raft::comms::op_t::MAX,
                   handle.get_stream());
  return ret.value(handle.get_stream());
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
edge_t graph_view_t<vertex_t,
                    edge_t,
                    weight_t,
                    store_transposed,
                    multi_gpu,
                    std::enable_if_t<!multi_gpu>>::compute_max_out_degree(raft::handle_t const&
                                                                            handle) const
{
  auto out_degrees = compute_out_degrees(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                out_degrees.begin(),
                                out_degrees.end());
  edge_t ret{0};
  if (it != out_degrees.end()) { raft::update_host(&ret, it, 1, handle.get_stream()); }
  handle.get_stream_view().synchronize();
  return ret;
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
weight_t
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_max_in_weight_sum(raft::handle_t const& handle) const
{
  auto in_weight_sums = compute_in_weight_sums(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                in_weight_sums.begin(),
                                in_weight_sums.end());
  rmm::device_scalar<weight_t> ret(weight_t{0.0}, handle.get_stream());
  device_allreduce(handle.get_comms(),
                   it != in_weight_sums.end() ? it : ret.data(),
                   ret.data(),
                   1,
                   raft::comms::op_t::MAX,
                   handle.get_stream());
  return ret.value(handle.get_stream());
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
weight_t graph_view_t<vertex_t,
                      edge_t,
                      weight_t,
                      store_transposed,
                      multi_gpu,
                      std::enable_if_t<!multi_gpu>>::compute_max_in_weight_sum(raft::handle_t const&
                                                                                 handle) const
{
  auto in_weight_sums = compute_in_weight_sums(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                in_weight_sums.begin(),
                                in_weight_sums.end());
  weight_t ret{0.0};
  if (it != in_weight_sums.end()) { raft::update_host(&ret, it, 1, handle.get_stream()); }
  handle.get_stream_view().synchronize();
  return ret;
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
weight_t
graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  compute_max_out_weight_sum(raft::handle_t const& handle) const
{
  auto out_weight_sums = compute_out_weight_sums(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                out_weight_sums.begin(),
                                out_weight_sums.end());
  rmm::device_scalar<weight_t> ret(weight_t{0.0}, handle.get_stream());
  device_allreduce(handle.get_comms(),
                   it != out_weight_sums.end() ? it : ret.data(),
                   ret.data(),
                   1,
                   raft::comms::op_t::MAX,
                   handle.get_stream());
  return ret.value(handle.get_stream());
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
weight_t graph_view_t<
  vertex_t,
  edge_t,
  weight_t,
  store_transposed,
  multi_gpu,
  std::enable_if_t<!multi_gpu>>::compute_max_out_weight_sum(raft::handle_t const& handle) const
{
  auto out_weight_sums = compute_out_weight_sums(handle);
  auto it = thrust::max_element(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                out_weight_sums.begin(),
                                out_weight_sums.end());
  weight_t ret{0.0};
  if (it != out_weight_sums.end()) { raft::update_host(&ret, it, 1, handle.get_stream()); }
  handle.get_stream_view().synchronize();
  return ret;
}

// explicit instantiation

template class graph_view_t<int32_t, int32_t, float, true, true>;
template class graph_view_t<int32_t, int32_t, float, false, true>;
template class graph_view_t<int32_t, int32_t, double, true, true>;
template class graph_view_t<int32_t, int32_t, double, false, true>;
template class graph_view_t<int32_t, int64_t, float, true, true>;
template class graph_view_t<int32_t, int64_t, float, false, true>;
template class graph_view_t<int32_t, int64_t, double, true, true>;
template class graph_view_t<int32_t, int64_t, double, false, true>;
template class graph_view_t<int64_t, int64_t, float, true, true>;
template class graph_view_t<int64_t, int64_t, float, false, true>;
template class graph_view_t<int64_t, int64_t, double, true, true>;
template class graph_view_t<int64_t, int64_t, double, false, true>;
template class graph_view_t<int64_t, int32_t, float, true, true>;
template class graph_view_t<int64_t, int32_t, float, false, true>;
template class graph_view_t<int64_t, int32_t, double, true, true>;
template class graph_view_t<int64_t, int32_t, double, false, true>;

template class graph_view_t<int32_t, int32_t, float, true, false>;
template class graph_view_t<int32_t, int32_t, float, false, false>;
template class graph_view_t<int32_t, int32_t, double, true, false>;
template class graph_view_t<int32_t, int32_t, double, false, false>;
template class graph_view_t<int32_t, int64_t, float, true, false>;
template class graph_view_t<int32_t, int64_t, float, false, false>;
template class graph_view_t<int32_t, int64_t, double, true, false>;
template class graph_view_t<int32_t, int64_t, double, false, false>;
template class graph_view_t<int64_t, int64_t, float, true, false>;
template class graph_view_t<int64_t, int64_t, float, false, false>;
template class graph_view_t<int64_t, int64_t, double, true, false>;
template class graph_view_t<int64_t, int64_t, double, false, false>;
template class graph_view_t<int64_t, int32_t, float, true, false>;
template class graph_view_t<int64_t, int32_t, float, false, false>;
template class graph_view_t<int64_t, int32_t, double, true, false>;
template class graph_view_t<int64_t, int32_t, double, false, false>;

}  // namespace experimental
}  // namespace cugraph
