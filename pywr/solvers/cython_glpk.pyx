from libc.stdlib cimport malloc, free
from libc.math cimport abs
from cython.view cimport array as cvarray
import numpy as np
cimport numpy as np

cimport cython

from pywr._core import BaseInput, BaseOutput, BaseLink
from pywr._core cimport *
from pywr.core import ModelStructureError
import time

include "glpk.pxi"

inf = float('inf')

cdef class AbstractNodeData:
    cdef public int id
    cdef public bint is_link

cdef class CythonGLPKSolver:
    cdef glp_prob* prob
    cdef glp_smcp smcp
    cdef int idx_col_routes
    cdef int idx_row_non_storages
    cdef int idx_row_cross_domain
    cdef int idx_row_storages
    cdef int idx_row_virtual_storages
    cdef int idx_row_aggregated
    cdef int idx_row_aggregated_min_max

    cdef public list routes
    cdef list non_storages
    cdef list storages
    cdef list virtual_storages
    cdef list aggregated

    cdef int[:] routes_cost
    cdef int[:] routes_cost_indptr

    cdef list all_nodes
    cdef int num_nodes
    cdef int num_routes
    cdef int num_storages
    cdef int num_scenarios
    cdef cvarray node_costs_arr
    cdef cvarray node_flows_arr
    cdef public cvarray route_flows_arr
    cdef public object stats

    # Internal representation of the basis for each scenario
    cdef int[:, :] row_stat
    cdef int[:, :] col_stat
    cdef bint is_first_solve
    cdef bint has_presolved
    cdef public bint use_presolve
    cdef public bint save_routes_flows
    cdef public bint retry_solve

    def __cinit__(self):
        # create a new problem
        self.prob = glp_create_prob()

    def __init__(self, use_presolve=False, time_limit=None, iteration_limit=None, message_level='error',
                 save_routes_flows=False, retry_solve=False):
        self.stats = None
        self.is_first_solve = True
        self.has_presolved = False
        self.use_presolve = use_presolve
        self.save_routes_flows = save_routes_flows
        self.retry_solve = retry_solve

        # Set solver options
        glp_init_smcp(&self.smcp)
        self.smcp.msg_lev = message_levels[message_level]
        if time_limit is not None:
            self.smcp.tm_lim = time_limit
        if iteration_limit is not None:
            self.smcp.it_lim = iteration_limit

        glp_term_hook(term_hook, NULL)

    def __dealloc__(self):
        # free the problem
        glp_delete_prob(self.prob)

    def setup(self, model):
        cdef Node input
        cdef Node output
        cdef AbstractNode some_node
        cdef AbstractNode _node
        cdef AggregatedNode agg_node
        cdef double min_flow
        cdef double max_flow
        cdef double cost
        cdef double avail_volume
        cdef int col, row
        cdef int* ind
        cdef double* val
        cdef double lb
        cdef double ub
        cdef Timestep timestep
        cdef int status
        cdef cross_domain_row
        cdef int n, num

        self.all_nodes = list(sorted(model.graph.nodes(), key=lambda n: n.fully_qualified_name))
        if not self.all_nodes:
            raise ModelStructureError("Model is empty")

        for n, _node in enumerate(self.all_nodes):
            _node.__data = AbstractNodeData()
            _node.__data.id = n
            if isinstance(_node, BaseLink):
                _node.__data.is_link = True

        self.num_nodes = len(self.all_nodes)

        self.node_costs_arr = cvarray(shape=(self.num_nodes,), itemsize=sizeof(double), format="d")
        self.node_flows_arr = cvarray(shape=(self.num_nodes,), itemsize=sizeof(double), format="d")

        routes = model.find_all_routes(BaseInput, BaseOutput, valid=(BaseLink, BaseInput, BaseOutput))
        # Find cross-domain routes
        cross_domain_routes = model.find_all_routes(BaseOutput, BaseInput, max_length=2, domain_match='different')

        non_storages = []
        storages = []
        virtual_storages = []
        aggregated_with_factors = []
        aggregated = []

        for some_node in self.all_nodes:
            if isinstance(some_node, (BaseInput, BaseLink, BaseOutput)):
                non_storages.append(some_node)
            elif isinstance(some_node, VirtualStorage):
                virtual_storages.append(some_node)
            elif isinstance(some_node, Storage):
                storages.append(some_node)
            elif isinstance(some_node, AggregatedNode):
                if some_node.factors is not None:
                    aggregated_with_factors.append(some_node)
                aggregated.append(some_node)

        if len(routes) == 0:
            raise ModelStructureError("Model has no valid routes")
        if len(non_storages) == 0:
            raise ModelStructureError("Model has no non-storage nodes")

        self.num_routes = len(routes)
        self.num_scenarios = len(model.scenarios.combinations)

        if self.save_routes_flows:
            # If saving flows this array needs to be 2D (one for each scenario)
            self.route_flows_arr = cvarray(shape=(self.num_scenarios, self.num_routes),
                                           itemsize=sizeof(double), format="d")
        else:
            # Otherwise the array can just be used to store a single solve to save some memory
            self.route_flows_arr = cvarray(shape=(self.num_routes, ), itemsize=sizeof(double), format="d")

        # clear the previous problem
        glp_erase_prob(self.prob)
        glp_set_obj_dir(self.prob, GLP_MIN)
        # add a column for each route
        self.idx_col_routes = glp_add_cols(self.prob, <int>(len(routes)))

        # create a lookup for the cross-domain routes.
        cross_domain_cols = {}
        for cross_domain_route in cross_domain_routes:
            # These routes are only 2 nodes. From output to input
            output, input = cross_domain_route
            # note that the conversion factor is not time varying
            conv_factor = input.get_conversion_factor()
            input_cols = [(n, conv_factor) for n, route in enumerate(routes) if route[0] is input]
            # create easy lookup for the route columns this output might
            # provide cross-domain connection to
            if output in cross_domain_cols:
                cross_domain_cols[output].extend(input_cols)
            else:
                cross_domain_cols[output] = input_cols

        # explicitly set bounds on route and demand columns
        for col, route in enumerate(routes):
            set_col_bnds(self.prob, self.idx_col_routes+col, GLP_LO, 0.0, DBL_MAX)

        # constrain supply minimum and maximum flow
        self.idx_row_non_storages = glp_add_rows(self.prob, len(non_storages))
        # Add rows for the cross-domain routes.
        if len(cross_domain_cols) > 0:
            self.idx_row_cross_domain = glp_add_rows(self.prob, len(cross_domain_cols))

        cross_domain_row = 0
        for row, some_node in enumerate(non_storages):
            # Differentiate betwen the node type.
            # Input & Output only apply their flow constraints when they
            # are the first and last node on the route respectively.
            if isinstance(some_node, BaseInput):
                cols = [n for n, route in enumerate(routes) if route[0] is some_node]
            elif isinstance(some_node, BaseOutput):
                cols = [n for n, route in enumerate(routes) if route[-1] is some_node]
            else:
                # Other nodes apply their flow constraints to all routes passing through them
                cols = [n for n, route in enumerate(routes) if some_node in route]
            ind = <int*>malloc((1+len(cols)) * sizeof(int))
            val = <double*>malloc((1+len(cols)) * sizeof(double))
            for n, c in enumerate(cols):
                ind[1+n] = 1+c
                val[1+n] = 1
            set_mat_row(self.prob, self.idx_row_non_storages+row, len(cols), ind, val)
            set_row_bnds(self.prob, self.idx_row_non_storages+row, GLP_FX, 0.0, 0.0)
            # glp_set_row_name(self.prob, self.idx_row_non_storages+row,
            #                  b'ns.'+some_node.fully_qualified_name.encode('utf-8'))
            free(ind)
            free(val)

            # Add constraint for cross-domain routes
            # i.e. those from a demand to a supply
            if some_node in cross_domain_cols:
                col_vals = cross_domain_cols[some_node]
                ind = <int*>malloc((1+len(col_vals)+len(cols)) * sizeof(int))
                val = <double*>malloc((1+len(col_vals)+len(cols)) * sizeof(double))
                for n, c in enumerate(cols):
                    ind[1+n] = 1+c
                    val[1+n] = -1
                for n, (c, v) in enumerate(col_vals):
                    ind[1+n+len(cols)] = 1+c
                    val[1+n+len(cols)] = 1./v
                set_mat_row(self.prob, self.idx_row_cross_domain+cross_domain_row, len(col_vals)+len(cols), ind, val)
                set_row_bnds(self.prob, self.idx_row_cross_domain+cross_domain_row, GLP_FX, 0.0, 0.0)
                # glp_set_row_name(self.prob, self.idx_row_cross_domain+cross_domain_row,
                #                  b'cd.'+some_node.fully_qualified_name.encode('utf-8'))
                free(ind)
                free(val)
                cross_domain_row += 1

        # storage
        if len(storages):
            self.idx_row_storages = glp_add_rows(self.prob, len(storages))
        for row, storage in enumerate(storages):
            cols_output = [n for n, route in enumerate(routes)
                           if route[-1] in storage.outputs and route[0] not in storage.inputs]
            cols_input = [n for n, route in enumerate(routes)
                          if route[0] in storage.inputs and route[-1] not in storage.outputs]
            ind = <int*>malloc((1+len(cols_output)+len(cols_input)) * sizeof(int))
            val = <double*>malloc((1+len(cols_output)+len(cols_input)) * sizeof(double))
            for n, c in enumerate(cols_output):
                ind[1+n] = self.idx_col_routes+c
                val[1+n] = 1
            for n, c in enumerate(cols_input):
                ind[1+len(cols_output)+n] = self.idx_col_routes+c
                val[1+len(cols_output)+n] = -1
            set_mat_row(self.prob, self.idx_row_storages+row, len(cols_output)+len(cols_input), ind, val)
            # glp_set_row_name(self.prob, self.idx_row_storages+row,
            #                  b's.'+storage.fully_qualified_name.encode('utf-8'))
            free(ind)
            free(val)

        # virtual storage
        if len(virtual_storages):
            self.idx_row_virtual_storages = glp_add_rows(self.prob, len(virtual_storages))
        for row, storage in enumerate(virtual_storages):
            # We need to handle the same route appearing twice here.
            cols = {}
            for n, route in enumerate(routes):
                for some_node in route:
                    try:
                        i = storage.nodes.index(some_node)
                    except ValueError:
                        pass
                    else:
                        try:
                            cols[n] += storage.factors[i]
                        except KeyError:
                            cols[n] = storage.factors[i]

            ind = <int*>malloc((1+len(cols)) * sizeof(int))
            val = <double*>malloc((1+len(cols)) * sizeof(double))
            for n, (c, f) in enumerate(cols.items()):
                ind[1+n] = self.idx_col_routes+c
                val[1+n] = -f

            set_mat_row(self.prob, self.idx_row_virtual_storages+row, len(cols), ind, val)
            # glp_set_row_name(self.prob, self.idx_row_virtual_storages+row,
            #                  b'vs.'+storage.fully_qualified_name.encode('utf-8'))
            free(ind)
            free(val)

        # aggregated node flow ratio constraints
        if len(aggregated_with_factors):
            self.idx_row_aggregated = self.idx_row_virtual_storages + len(virtual_storages)
        for agg_node in aggregated_with_factors:
            nodes = agg_node.nodes
            factors = agg_node.factors
            assert(len(nodes) == len(factors))

            row = glp_add_rows(self.prob, len(agg_node.nodes)-1)

            cols = []
            for node in nodes:
                cols.append([n for n, route in enumerate(routes) if node in route])

            # normalise factors
            f0 = factors[0]
            factors_norm = [f0/f for f in factors]

            # update matrix
            for n in range(len(nodes)-1):
                length = len(cols[0])+len(cols[n+1])
                ind = <int*>malloc(1+length * sizeof(int))
                val = <double*>malloc(1+length * sizeof(double))
                for i, c in enumerate(cols[0]):
                    ind[1+i] = 1+c
                    val[1+i] = 1.0
                for i, c in enumerate(cols[n+1]):
                    ind[1+len(cols[0])+i] = 1+c
                    val[1+len(cols[0])+i] = -factors_norm[n+1]
                set_mat_row(self.prob, row+n, length, ind, val)
                free(ind)
                free(val)

                set_row_bnds(self.prob, row+n, GLP_FX, 0.0, 0.0)
                # glp_set_row_name(self.prob, row+n,
                #                  'ag.f{}.{}'.format(n, agg_node.fully_qualified_name).encode('utf-8'))

        # aggregated node min/max flow constraints
        if aggregated:
            self.idx_row_aggregated_min_max = glp_add_rows(self.prob, len(aggregated))
        for row, agg_node in enumerate(aggregated):
            row = self.idx_row_aggregated_min_max + row
            nodes = agg_node.nodes

            weights = agg_node.flow_weights
            if weights is None:
                weights = [1.0]*len(nodes)

            matrix = {}
            for some_node, w in zip(nodes, weights):
                for n, route in enumerate(routes):
                    if some_node in route:
                        matrix[n] = w
            length = len(matrix)
            ind = <int*>malloc(1+length * sizeof(int))
            val = <double*>malloc(1+length * sizeof(double))
            for i, col in enumerate(sorted(matrix)):
                ind[1+i] = 1+col
                val[1+i] = matrix[col]
            set_mat_row(self.prob, row, length, ind, val)
            set_row_bnds(self.prob, row, GLP_FX, 0.0, 0.0)
            # glp_set_row_name(self.prob, row, b'ag.'+agg_node.fully_qualified_name.encode('utf-8'))
            free(ind)
            free(val)

        # update route properties
        routes_cost = []
        routes_cost_indptr = [0, ]
        for col, route in enumerate(routes):
            route_cost = []
            route_cost.append(route[0].__data.id)
            for some_node in route[1:-1]:
                if isinstance(some_node, BaseLink):
                    route_cost.append(some_node.__data.id)
            route_cost.append(route[-1].__data.id)
            routes_cost.extend(route_cost)
            routes_cost_indptr.append(len(routes_cost))

        assert(len(routes_cost_indptr) == len(routes) + 1)

        self.routes_cost_indptr = np.array(routes_cost_indptr, dtype=np.int32)
        self.routes_cost = np.array(routes_cost, dtype=np.int32)

        self.routes = routes
        self.non_storages = non_storages
        self.storages = storages
        self.virtual_storages = virtual_storages
        self.aggregated = aggregated

        self._init_basis_arrays(model)
        self.is_first_solve = True
        self.has_presolved = False

        # reset stats
        self.stats = {
            'total': 0.0,
            'lp_solve': 0.0,
            'result_update': 0.0,
            'bounds_update_nonstorage': 0.0,
            'bounds_update_storage': 0.0,
            'bounds_update_nonstorage': 0.0,
            'bounds_update_storage': 0.0,
            'objective_update': 0.0,
            'number_of_rows': glp_get_num_rows(self.prob),
            'number_of_cols': glp_get_num_cols(self.prob),
            'number_of_nonzero': glp_get_num_nz(self.prob),
            'number_of_routes': len(routes),
            'number_of_nodes': len(self.all_nodes)
        }

    cdef _init_basis_arrays(self, model):
        """ Initialise the arrays used for storing the LP basis by scenario """
        cdef int nscenarios = len(model.scenarios.combinations)
        cdef int nrows = glp_get_num_rows(self.prob)
        cdef int ncols = glp_get_num_cols(self.prob)

        self.row_stat = np.empty((nscenarios, nrows), dtype=np.int32)
        self.col_stat = np.empty((nscenarios, ncols), dtype=np.int32)

    cdef _save_basis(self, int global_id):
        """ Save the current basis for scenario associated with global_id """
        cdef int i
        cdef int nrows = glp_get_num_rows(self.prob)
        cdef int ncols = glp_get_num_cols(self.prob)

        for i in range(nrows):
            self.row_stat[global_id, i] = glp_get_row_stat(self.prob, i+1)
        for i in range(ncols):
            self.col_stat[global_id, i] = glp_get_col_stat(self.prob, i+1)

    cdef _set_basis(self, int global_id):
        """ Set the current basis for scenario associated with global_id """
        cdef int i, nrows, ncols

        if self.is_first_solve:
            # First time solving we use the default advanced basis
            glp_adv_basis(self.prob, 0)
        else:
            # otherwise we restore basis from previous solve of this scenario
            nrows = glp_get_num_rows(self.prob)
            ncols = glp_get_num_cols(self.prob)

            for i in range(nrows):
                glp_set_row_stat(self.prob, i+1, self.row_stat[global_id, i])
            for i in range(ncols):
                glp_set_col_stat(self.prob, i+1, self.col_stat[global_id, i])

    def reset(self):
        # Resetting this triggers a crashing of a new basis in each scenario
        self.is_first_solve = True

    cpdef object solve(self, model):
        t0 = time.perf_counter()
        cdef int[:] scenario_combination
        cdef int scenario_id
        cdef ScenarioIndex scenario_index
        for scenario_index in model.scenarios.combinations:
            self._solve_scenario(model, scenario_index)
        self.stats['total'] += time.perf_counter() - t0
        # After solving this is always false
        self.is_first_solve = False

    @cython.boundscheck(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cdef object _solve_scenario(self, model, ScenarioIndex scenario_index):
        cdef Node node
        cdef Storage storage
        cdef AbstractNode _node
        cdef AbstractNodeData data
        cdef AggregatedNode agg_node
        cdef double min_flow
        cdef double max_flow
        cdef double cost
        cdef double max_volume
        cdef double min_volume
        cdef double avail_volume
        cdef double t0
        cdef int col, row
        cdef int* ind
        cdef double* val
        cdef double lb
        cdef double ub
        cdef Timestep timestep
        cdef int status, simplex_ret
        cdef cross_domain_col
        cdef list route
        cdef int node_id, indptr, nroutes
        cdef double flow
        cdef int n, m
        cdef Py_ssize_t length

        timestep = model.timestep
        cdef list routes = self.routes
        nroutes = len(routes)
        cdef list non_storages = self.non_storages
        cdef list storages = self.storages
        cdef list virtual_storages = self.virtual_storages
        cdef list aggregated = self.aggregated

        # update route cost

        t0 = time.perf_counter()

        # update the cost of each node in the model
        cdef double[:] node_costs = self.node_costs_arr
        for _node in self.all_nodes:
            data = _node.__data
            node_costs[data.id] = _node.get_cost(scenario_index)

        # calculate the total cost of each route
        for col in range(nroutes):
            cost = 0.0
            for indptr in range(self.routes_cost_indptr[col], self.routes_cost_indptr[col+1]):
                node_id = self.routes_cost[indptr]
                cost += node_costs[node_id]

            if abs(cost) < 1e-8:
                cost = 0.0
            set_obj_coef(self.prob, self.idx_col_routes+col, cost)

        self.stats['objective_update'] += time.perf_counter() - t0
        t0 = time.perf_counter()

        # update non-storage properties
        for row, node in enumerate(non_storages):
            min_flow = inf_to_dbl_max(node.get_min_flow(scenario_index))
            if abs(min_flow) < 1e-8:
                min_flow = 0.0
            max_flow = inf_to_dbl_max(node.get_max_flow(scenario_index))
            if abs(max_flow) < 1e-8:
                max_flow = 0.0
            set_row_bnds(self.prob, self.idx_row_non_storages+row, constraint_type(min_flow, max_flow),
                         min_flow, max_flow)

        for row, agg_node in enumerate(aggregated):
            min_flow = inf_to_dbl_max(agg_node.get_min_flow(scenario_index))
            if abs(min_flow) < 1e-8:
                min_flow = 0.0
            max_flow = inf_to_dbl_max(agg_node.get_max_flow(scenario_index))
            if abs(max_flow) < 1e-8:
                max_flow = 0.0
            set_row_bnds(self.prob, self.idx_row_aggregated_min_max + row, constraint_type(min_flow, max_flow),
                         min_flow, max_flow)

        self.stats['bounds_update_nonstorage'] += time.perf_counter() - t0
        t0 = time.perf_counter()

        # update storage node constraint
        for row, storage in enumerate(storages):
            max_volume = storage.get_max_volume(scenario_index)
            min_volume = storage.get_min_volume(scenario_index)

            if max_volume == min_volume:
                set_row_bnds(self.prob, self.idx_row_storages+row, GLP_FX, 0.0, 0.0)
            else:
                avail_volume = max(storage._volume[scenario_index.global_id] - min_volume, 0.0)
                # change in storage cannot be more than the current volume or
                # result in maximum volume being exceeded
                lb = -avail_volume/timestep._days
                ub = max(max_volume - storage._volume[scenario_index.global_id], 0.0) / timestep._days

                if abs(lb) < 1e-8:
                    lb = 0.0
                if abs(ub) < 1e-8:
                    ub = 0.0
                set_row_bnds(self.prob, self.idx_row_storages+row, constraint_type(lb, ub), lb, ub)

        # update virtual storage node constraint
        for row, storage in enumerate(virtual_storages):
            max_volume = storage.get_max_volume(scenario_index)
            min_volume = storage.get_min_volume(scenario_index)

            if max_volume == min_volume:
                set_row_bnds(self.prob, self.idx_row_virtual_storages+row, GLP_FX, 0.0, 0.0)
            else:
                avail_volume = max(storage._volume[scenario_index.global_id] - min_volume, 0.0)
                # change in storage cannot be more than the current volume or
                # result in maximum volume being exceeded
                lb = -avail_volume/timestep._days
                ub = max(max_volume - storage._volume[scenario_index.global_id], 0.0) / timestep._days

                if abs(lb) < 1e-8:
                    lb = 0.0
                if abs(ub) < 1e-8:
                    ub = 0.0
                set_row_bnds(self.prob, self.idx_row_virtual_storages+row, constraint_type(lb, ub), lb, ub)

        self.stats['bounds_update_storage'] += time.perf_counter() - t0

        t0 = time.perf_counter()

        # Apply presolve if required
        if self.use_presolve and not self.has_presolved:
            self.smcp.presolve = GLP_ON
            self.has_presolved = True
        else:
            self.smcp.presolve = GLP_OFF

        # Set the basis for this scenario
        self._set_basis(scenario_index.global_id)
        # attempt to solve the linear programme
        simplex_ret = simplex(self.prob, self.smcp)
        status = glp_get_status(self.prob)
        if (status != GLP_OPT or simplex_ret != 0) and self.retry_solve:
            # try creating a new basis and resolving
            print('Retrying solve with new basis.')
            glp_std_basis(self.prob)
            simplex_ret = simplex(self.prob, self.smcp)
            status = glp_get_status(self.prob)

        if status != GLP_OPT or simplex_ret != 0:
            # If problem is not solved. Print some debugging information and error.
            print("Simplex solve returned: {} ({})".format(simplex_status_string[simplex_ret], simplex_ret))
            print("Simplex status: {} ({})".format(status_string[status], status))
            print("Scenario ID: {}".format(scenario_index.global_id))
            print("Timestep index: {}".format(timestep._index))
            self.dump_mps(b'pywr_glpk_debug.mps')
            self.dump_lp(b'pywr_glpk_debug.lp')

            self.smcp.msg_lev = GLP_MSG_DBG
            # Retry solve with debug messages
            simplex_ret = simplex(self.prob, self.smcp)
            status = glp_get_status(self.prob)
            raise RuntimeError('Simplex solver failed with message: "{}", status: "{}".'.format(
                simplex_status_string[simplex_ret], status_string[status]))
        # Now save the basis
        self._save_basis(scenario_index.global_id)

        self.stats['lp_solve'] += time.perf_counter() - t0
        t0 = time.perf_counter()

        cdef double[:] route_flows
        if self.save_routes_flows:
            route_flows = self.route_flows_arr[scenario_index.global_id, :]
        else:
            route_flows = self.route_flows_arr

        for col in range(0, self.num_routes):
            route_flows[col] = glp_get_col_prim(self.prob, col+1)

        # collect the total flow via each node
        cdef double[:] node_flows = self.node_flows_arr
        node_flows[:] = 0.0
        for n, route in enumerate(routes):
            flow = route_flows[n]
            if flow == 0:
                continue
            length = len(route)
            for m, _node in enumerate(route):
                data = _node.__data
                if (m == 0) or (m == length-1) or data.is_link:
                    node_flows[data.id] += flow

        # commit the total flows
        for n in range(0, self.num_nodes):
            _node = self.all_nodes[n]
            _node.commit(scenario_index.global_id, node_flows[n])

        self.stats['result_update'] += time.perf_counter() - t0

    cpdef dump_mps(self, filename):
        glp_write_mps(self.prob, GLP_MPS_FILE, NULL, filename)

    cpdef dump_lp(self, filename):
        glp_write_lp(self.prob, NULL, filename)

    cpdef dump_glpk(self, filename):
        glp_write_prob(self.prob, 0, filename)


cdef int simplex(glp_prob *P, glp_smcp parm):
    return glp_simplex(P, &parm)


cdef set_obj_coef(glp_prob *P, int j, double coef):
    IF SOLVER_DEBUG:
        assert np.isfinite(coef)
        if abs(coef) < 1e-9:
            if abs(coef) != 0.0:
                print(j, coef)
                assert False
    glp_set_obj_coef(P, j, coef)


cdef set_row_bnds(glp_prob *P, int i, int type, double lb, double ub):
    IF SOLVER_DEBUG:
        assert np.isfinite(lb)
        assert np.isfinite(ub)
        assert lb <= ub
        if abs(lb) < 1e-9:
            if abs(lb) != 0.0:
                print(i, type, lb, ub)

                assert False
        if abs(ub) < 1e-9:
            if abs(ub) != 0.0:
                print(i, type, lb, ub)
                assert False

    glp_set_row_bnds(P, i, type, lb, ub)


cdef set_col_bnds(glp_prob *P, int i, int type, double lb, double ub):
    IF SOLVER_DEBUG:
        assert np.isfinite(lb)
        assert np.isfinite(ub)
        assert lb <= ub
    glp_set_col_bnds(P, i, type, lb, ub)


cdef set_mat_row(glp_prob *P, int i, int len, int* ind, double* val):
    IF SOLVER_DEBUG:
        cdef int j
        for j in range(len):
            assert np.isfinite(val[j+1])
            assert abs(val[j+1]) > 1e-6
            assert ind[j+1] > 0

    glp_set_mat_row(P, i, len, ind, val)
