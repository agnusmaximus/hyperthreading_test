import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.pyplot import cm
import numpy as np
import sys
import os

def get_sm_times(fname):
    f = open(fname)
    data = {}
    n_bars = 0
    for line in f:
        if line[0] == '-':
            sm_id, name, start_clock, end_clock = line.split(" ")[1:]
            sm_id, start_clock, end_clock = int(sm_id), int(start_clock), int(end_clock)
            if name not in data:
                data[name] = {}
            if sm_id not in data[name]:
                data[name][sm_id] = []
            if len(data[name][sm_id]) == 0:
                n_bars += 1
            data[name][sm_id].append((start_clock, end_clock))
            
    f.close()

    for name, sm_id_and_times in data.items():
        min_start_time = float("inf")
        for sm_id, times in sm_id_and_times.items():
            min_start_time = min([min_start_time] + [x[0] for x in times])
        for sm_id, times in sm_id_and_times.items():
            for i, (start,end) in enumerate(times):
                data[name][sm_id][i] = (start-min_start_time, end-min_start_time)

    print(data)
    return data, n_bars    

def plot_sm_timeline(fname):
    data, n_bars = get_sm_times(fname)
    base_index = 0
    min_time, max_time = float("inf"), -1
    color=iter(cm.rainbow(np.linspace(0,1,n_bars)))
    linewidth = 3
    increments = linewidth + 20

    cmap = plt.get_cmap('gnuplot')
    colors = [cmap(i) for i in np.linspace(0, 1, n_bars)]
    index = 0
    handles, labels = [], []


    for name, sm_id_and_times in data.items():
        for sm_id, times in sm_id_and_times.items():
            start_times = [x[0] for x in times]
            end_times = [x[1] for x in times]
            label = name
            handle = plt.hlines([base_index + x * increments for x in range(len(times))], start_times, end_times, linewidth=linewidth, label=label, color=colors[index])
            handles.append(handle)
            labels.append(label)
            min_time = min(start_times + [min_time])
            max_time = max(end_times + [max_time])
            base_index += increments * len(times) + 5
            index += 1
        base_index += increments * 3

    plt.tight_layout()
        
    plt.ylim([-increments*3, base_index+increments*3])
    plt.title("SM_Timeline")
    plt.xlabel("Clock Cycles")
    plt.legend(handles[::-1], labels[::-1], bbox_to_anchor=(1.05, 1), loc=2, borderaxespad=0., fontsize=13)
    plt.savefig("sm_timeline.png", bbox_inches='tight')            

if __name__=="__main__":
    if len(sys.argv) < 2:
        print("Usage: python plot_sm_timeline.py f_name")
        sys.exit(-1)
    plot_sm_timeline(sys.argv[1])
