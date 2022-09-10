#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"
#include <device_launch_parameters.h>

// potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// Grid parameters based on simulation parameters.
// These are automatically computed in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* basic helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");
  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");
  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects, dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, numObjects * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");
  cudaMalloc((void**)&dev_particleGridIndices, numObjects * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");
  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");
  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3* pos, float* vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3* vel, float* vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float* vbodptr_positions, float* vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3* pos, const glm::vec3* vel) {
  // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
  // Rule 2: boids try to stay a distance d away from each other
  // Rule 3: boids try to match the speed of surrounding boids
  glm::vec3 perceivedCenter = glm::vec3(0.f);
  glm::vec3 c = glm::vec3(0.f);
  glm::vec3 perceivedVel = glm::vec3(0.f);
  int neighborInRule1Dist = 0;
  int neighborInRule3Dist = 0;
  for (int i = 0; i < N; ++i) {
    if (i != iSelf) {
      float dist = glm::distance(pos[i], pos[iSelf]);
      if (dist < rule1Distance) {
        perceivedCenter += pos[i];
        ++neighborInRule1Dist;
      }
      if (dist < rule2Distance) {
        c -= (pos[i] - pos[iSelf]);
      }
      if (dist < rule3Distance) {
        perceivedVel += vel[i];
        ++neighborInRule3Dist;
      }
    }
  }

  glm::vec3 velChange = glm::vec3(0.f);
  if (neighborInRule1Dist > 0) {
    perceivedCenter /= neighborInRule1Dist;
    velChange += (perceivedCenter - pos[iSelf]) * rule1Scale;
  }
  velChange += c * rule2Scale;
  if (neighborInRule3Dist > 0) {
    perceivedVel /= neighborInRule3Dist;
    velChange += perceivedVel * rule3Scale;
  }
  return velChange;
}

/**
* implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  int i = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (i >= N) { return; }
  // Compute a new velocity based on pos and vel1
  // Record in new vel2. (since vel1 may still need to be referenced for rule3)
  vel2[i] = vel1[i] + computeVelocityChange(N, i, pos, vel1);

  // Clamp speed if needed
  if (glm::length(vel2[i]) > maxSpeed) {
    vel2[i] = glm::normalize(vel2[i]) * maxSpeed;
  }
}

/**
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, glm::vec3* pos, int* indices, int* gridIndices) {
  int i = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (i >= N) { return; }
  // parallel array of indices as pointers to the actual boid data in pos and vel1/vel2
  indices[i] = i;
  // Label each boid with the index of its grid cell.
  glm::vec3 posInCell = (pos[i] - gridMin) * inverseCellWidth;
  gridIndices[i] = gridIndex3Dto1D(int(posInCell.x), int(posInCell.y), int(posInCell.z),
    gridResolution);
}

// indicating that a cell does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  int i = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (i >= N) { return; }
  // Identify the start point of each cell in the gridIndices array.
  // parallel unrolling of a loop
  int currBoidIdx = particleGridIndices[i]; // index IN dev_pos or whatever
  if (i == N - 1) {
    gridCellEndIndices[currBoidIdx] = i;
    return;
  }

  int nextBoidIdx = particleGridIndices[i + 1];
  if (i == 0) {
    gridCellStartIndices[currBoidIdx] = i;
  }
  // "this index doesn't match the one before it, must be a new cell!"
  if (currBoidIdx != nextBoidIdx) {
    gridCellEndIndices[currBoidIdx] = i + 1;
    gridCellStartIndices[nextBoidIdx] = i + 1;
  } 
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // Update a boid's velocity using the uniform grid
  int currIdx = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (currIdx >= N) { return; }
  // - Identify the grid cell that this particle is in
  glm::vec3 posRelativeToGrid = pos[currIdx] - gridMin;
  glm::vec3 posInCell = posRelativeToGrid * inverseCellWidth;
  glm::vec3 posOfCell = glm::vec3(int(posInCell.x), int(posInCell.y), int(posInCell.z));
  int gridCellIdx = gridIndex3Dto1D(posOfCell.x, posOfCell.y, posOfCell.z, gridResolution);
  // Identify which cells may contain neighbors. This isn't always 8.
  glm::vec3 posRelativeToCell = posRelativeToGrid - (posOfCell * cellWidth);
  int xSearchDir = posRelativeToCell.x > cellWidth / 2 ? 1 : -1;
  int ySearchDir = posRelativeToCell.y > cellWidth / 2 ? 1 : -1;
  int zSearchDir = posRelativeToCell.z > cellWidth / 2 ? 1 : -1;

  //For each cell, read the start/end indices in the boid pointer array.
  glm::vec3 perceivedCenter = glm::vec3(0.f);
  glm::vec3 c = glm::vec3(0.f);
  glm::vec3 perceivedVel = glm::vec3(0.f);
  int neighborInRule1Dist = 0;
  int neighborInRule3Dist = 0;
  for (int x = 0; abs(x) <= abs(xSearchDir); ++x) {
    for (int y = 0; abs(y) <= abs(ySearchDir); ++y) {
      for (int z = 0; abs(z) <= abs(zSearchDir); ++z) {
        int neighborCellIdx = gridCellIdx + 
          x + y * gridResolution + z * gridResolution * gridResolution;
        // gridRes ^ 3 == gridCellCount
        if (neighborCellIdx < 0 || 
          gridResolution * gridResolution * gridResolution <= neighborCellIdx) { continue; }
        int gridStart = gridCellStartIndices[neighborCellIdx];
        if (gridStart == -1) { continue; }
        // Access each boid in the cell, compute vel change from boids rules
        for (int arrIdx = gridStart; arrIdx < gridCellEndIndices[neighborCellIdx]; ++arrIdx) {
          int neighborIdx = particleArrayIndices[arrIdx];
          if (currIdx == neighborIdx) { continue; }
          // Rule 1: boids fly towards their local perceived center of mass
          // Rule 2: boids try to stay a distance d away from each other
          // Rule 3: boids try to match the speed of surrounding boids
          float dist = glm::distance(pos[neighborIdx], pos[currIdx]);
          if (dist < rule1Distance) {
            perceivedCenter += pos[neighborIdx];
            ++neighborInRule1Dist;
          }
          if (dist < rule2Distance) {
            c -= (pos[neighborIdx] - pos[currIdx]);
          }
          if (dist < rule3Distance) {
            perceivedVel += vel1[neighborIdx];
            ++neighborInRule3Dist;
          }
        }
      }
    }
  }
  glm::vec3 velChange = glm::vec3(0.f);
  if (neighborInRule1Dist > 0) {
    perceivedCenter /= neighborInRule1Dist;
    velChange += (perceivedCenter - pos[currIdx]) * rule1Scale;
  }
  velChange += c * rule2Scale;
  if (neighborInRule3Dist > 0) {
    perceivedVel /= neighborInRule3Dist;
    velChange += perceivedVel * rule3Scale;
  }
  vel2[currIdx] = vel1[currIdx] + velChange;
  // Clamp speed if needed
  if (glm::length(vel2[currIdx]) > maxSpeed) {
    vel2[currIdx] = glm::normalize(vel2[currIdx]) * maxSpeed;
  }
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // use kernels to step the simulation forward in time.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");
  // ping-pong velocity buffers
  std::swap(dev_vel1, dev_vel2);
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel1);
  checkCUDAErrorWithLine("kernUpdatePos failed!");
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // Uniform Grid Neighbor search using Thrust sort.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids. (should have already been done in init ?)
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>(numObjects, gridSideCount,
    gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices,
    dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");
  // Unstable key sort using Thrust. stable sort isn't necessary
  thrust::sort_by_key(dev_thrust_particleGridIndices,
    dev_thrust_particleGridIndices + numObjects,
    dev_thrust_particleArrayIndices);

  // Naively unroll the loop for finding the start and end indices of each
  // cell's data pointers in the array of boid indices
  dim3 fullBlocksPerCell((gridCellCount + blockSize - 1) / blockSize);
  kernResetIntBuffer<<<fullBlocksPerCell, blockSize>>>(gridCellCount,
    dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(numObjects,
    dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");
  // velocity updates using neighbor search
  kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid, blockSize>>>(numObjects,
    gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth,
    dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices,
    dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");
  // ping poing, Update positions
  std::swap(dev_vel1, dev_vel2);
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel1);
  checkCUDAErrorWithLine("kernUpdatePos failed!");
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
}

void Boids::unitTest() {
  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
