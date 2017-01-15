import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
import sys
import os

def get_sm_times(fname):
    f = open(fname)
    data = {}
    for line in f:
        if line[0] == '-':
            sm_id, name, start_clock, end_clock = line.split(" ")[1:]
            sm_id, start_clock, end_clock = int(sm_id), int(start_clock), int(end_clock)
            if name not in data:
                data[name] = {}
            if sm_id not in data[name]:
                data[name][sm_id] = []
            data[name][sm_id].append((start_clock, end_clock))
    f.close()

    for name, sm_id_and_times in data.items():
        min_start_time = float("inf")
        for sm_id, times in sm_id_and_times.items():
            min_start_time = min([min_start_time] + [x[0] for x in times])
        for sm_id, times in sm_id_and_times.items():
            for i, (start,end) in enumerate(times):
                data[name][sm_id][i] = (start-min_start_time, end-min_start_time)
    return data    

def plot_sm_timeline(fname):
    data = get_sm_times(fname)
    base_index = 0
    min_time, max_time = float("inf"), -1
    for name, sm_id_and_times in data.items():
        for sm_id, times in sm_id_and_times.items():
            print(times)
            start_times = [x[0] for x in times]
            end_times = [x[1] for x in times]
            plt.hlines([base_index + x for x in range(len(times))], start_times, end_times, linewidth=15, label="%s_%d" % (name, sm_id))
            min_time = min(start_times + [min_time])
            max_time = max(end_times + [max_time])
            base_index += 10
        
    plt.title("SM_Timeline")
    plt.xlabel("Clock Cycles")
    plt.legend(bbox_to_anchor=(1.05, 1), loc=2, borderaxespad=0.)
    plt.savefig("sm_timeline.png", bbox_inches='tight')
        
    

if __name__=="__main__":
    if len(sys.argv) < 2:
        print("Usage: python plot_sm_timeline.py f_name")
        sys.exit(-1)
    plot_sm_timeline(sys.argv[1])
