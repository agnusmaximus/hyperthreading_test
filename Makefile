
HWLOC_CFLAGS=$(shell pkg-config --cflags hwloc)
HWLOC_LFLAGS=$(shell pkg-config --libs hwloc)
FLAGS=-std=c++11
CC=g++

all:
	$(CC) $(FLAGS) hyperthreading_test.cpp -fopenmp $(HWLOC_CFLAGS) $(HWLOC_LFLAGS) -lhwloc -o hyperthreading_test

run:
	make all
	./hyperthreading_test
