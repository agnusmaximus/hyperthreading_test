#include <iostream>
#include <omp.h>
#include <chrono>
#include <hwloc.h>

#define N_WORK ((long long int)1000000000)

using namespace std;

hwloc_topology_t topology;

void init() {
    hwloc_topology_init(&topology);
    hwloc_topology_load(topology);
}

int get_num_physical_cores() {
    return hwloc_get_nbobjs_by_depth(topology, HWLOC_OBJ_CORE);
}

int get_num_logical_cores() {
    return hwloc_get_nbobjs_by_depth(topology, HWLOC_OBJ_PU);
}

int get_num_logical_core_for_core(int core) {
    hwloc_obj_t obj = hwloc_get_obj_by_depth(topology,
					     hwloc_get_type_depth(topology, HWLOC_OBJ_CORE),
					     core);
    return obj->arity;
}

void pin_to_core(int physical_core_index, int logical_core_index) {
    if (logical_core_index < 0 || logical_core_index >= get_num_logical_core_for_core(physical_core_index)) {
	cout << "Logical core index: " << logical_core_index << " beyond index." << endl;
	exit(-1);
    }
    hwloc_obj_t obj = hwloc_get_obj_by_depth(topology,
					     hwloc_get_type_depth(topology, HWLOC_OBJ_CORE),
					     physical_core_index);
    hwloc_obj_t logical_core = obj->first_child;
    for (int i = 0; i < logical_core_index; i++) {
	logical_core = logical_core->next_sibling;
    }

    hwloc_set_cpubind(topology, logical_core->cpuset, HWLOC_CPUBIND_THREAD);
}

void cleanup() {
    hwloc_topology_destroy(topology);
}

double physical_core_matrix_multiply(int n_work) {
    omp_set_num_threads(get_num_physical_cores());

    auto wcts = std::chrono::system_clock::now();

#pragma omp parallel
    {
	pin_to_core(omp_get_thread_num(), 0);
	int sum = 0;
	for (int i = 0; i < n_work; i++) {
	    sum += i;
	}
    }

    chrono::duration<double> duration = (chrono::system_clock::now() - wcts);
    return duration.count();
}

double logical_core_matrix_multiply(int n_work) {
    omp_set_num_threads(get_num_logical_cores());

    auto wcts = std::chrono::system_clock::now();

#pragma omp parallel
    {
	int physical_core = omp_get_thread_num() / get_num_physical_cores();
	int logical_core = omp_get_thread_num() % get_num_physical_cores();

	pin_to_core(physical_core, logical_core);
	int sum = 0;
	for (int i = 0; i < n_work; i++) {
	    sum += i;
	}
    }

    chrono::duration<double> duration = (chrono::system_clock::now() - wcts);
    return duration.count();
}

int main(void) {

    init();

    cout << "Number of physical cores: " << get_num_physical_cores() << std::endl;
    cout << "Number of logical cores: " << get_num_logical_cores() << std::endl;

    double t_phys = physical_core_matrix_multiply(N_WORK);
    double t_logical = logical_core_matrix_multiply(N_WORK);
    double gflops_phys = (N_WORK * get_num_physical_cores() / 1e9) / t_phys;
    double gflops_logical = (N_WORK * get_num_logical_cores() / 1e9) / t_logical;

    cout << "t_phys: " << t_phys << " t_logical: " << t_logical << endl;
    cout << "gflops_phys: " << gflops_phys << " gflops_logical: " << gflops_logical << endl;

    cleanup();
}
