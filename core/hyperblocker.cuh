#ifndef HYPERBLOCKER_CORE_HYPER_BLOCKER_CUH_
#define HYPERBLOCKER_CORE_HYPER_BLOCKER_CUH_

#include <condition_variable>
#include <ctime>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <experimental/filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "core/components/data_mngr.h"
#include "core/components/execution_plan_generator.h"
#include "core/components/host_producer.h"
#include "core/components/host_reducer.h"
#include "core/components/scheduler/CHBL_scheduler.h"
#include "core/components/scheduler/even_split_scheduler.h"
#include "core/components/scheduler/round_robin_scheduler.h"
#include "core/components/scheduler/scheduler.h"
#include "core/data_structures/match.h"

namespace sics {
namespace hyperblocker {
namespace core {

using sics::hyperblocker::core::components::DataMngr;
using sics::hyperblocker::core::components::ExecutionPlanGenerator;
using sics::hyperblocker::core::components::HostProducer;
using sics::hyperblocker::core::components::HostReducer;
using sics::hyperblocker::core::components::scheduler::kCHBL;
using sics::hyperblocker::core::components::scheduler::kEvenSplit;
using sics::hyperblocker::core::components::scheduler::kRoundRobin;
using sics::hyperblocker::core::data_structures::Match;
using sics::hyperblocker::core::data_structures::Rule;

class HyperBlocker {
public:
  HyperBlocker() = delete;

  HyperBlocker(const std::string &rule_dir, const std::string &data_path_l,
               const std::string &data_path_r, const std::string &output_path,
               int n_partitions, int prefix_hash_predicate_index = INT_MAX,
               const std::string &sep = ",",
               components::scheduler::SchedulerType scheduler_type = kCHBL)
      : rule_dir_(rule_dir), data_path_l_(data_path_l),
        data_path_r_(data_path_r), output_path_(output_path),
        n_partitions_(n_partitions),
        prefix_hash_predicate_index_(prefix_hash_predicate_index) {

    Init();

    auto start_time = std::chrono::system_clock::now();

    p_streams_mtx_ = std::make_unique<std::mutex>();

    p_hr_start_mtx_ = std::make_unique<std::mutex>();
    p_hr_start_lck_ =
        std::make_unique<std::unique_lock<std::mutex>>(*p_hr_start_mtx_.get());
    p_hr_start_cv_ = std::make_unique<std::condition_variable>();
    streams_ = std::make_unique<std::unordered_map<int, cudaStream_t *>>();

    epg_ = std::make_unique<ExecutionPlanGenerator>(rule_dir_);

    switch (scheduler_type) {
    case kCHBL:
      scheduler_ =
          std::make_unique<components::scheduler::CHBLScheduler>(n_device_);
      break;
    case kEvenSplit:
      scheduler_ = std::make_unique<components::scheduler::EvenSplitScheduler>(
          n_device_);
      break;
    case kRoundRobin:
      scheduler_ = std::make_unique<components::scheduler::RoundRobinScheduler>(
          n_device_);
      break;
    }

    data_mngr_ =
        std::make_unique<sics::hyperblocker::core::components::DataMngr>(
            data_path_l_, data_path_r_, sep, false);

    p_match_ = std::make_unique<Match>();

    p_hr_terminable_ = std::make_unique<bool>(false);

    auto end_time = std::chrono::system_clock::now();
    std::cout << "HyperBlocker.Initialize() elapsed: "
              << std::chrono::duration_cast<std::chrono::microseconds>(
                     end_time - start_time)
                         .count() /
                     (double)CLOCKS_PER_SEC
              << std::endl;
  }

  ~HyperBlocker() = default;

  void Run() {

    auto start_time = std::chrono::system_clock::now();

    // ShowDeviceProperties();
    HostProducer hp(n_partitions_, data_mngr_.get(), epg_.get(),
                    scheduler_.get(), streams_.get(), p_streams_mtx_.get(),
                    p_match_.get(), p_hr_start_lck_.get(), p_hr_start_cv_.get(),
                    p_hr_terminable_.get(), prefix_hash_predicate_index_);
    HostReducer hr(output_path_, scheduler_.get(), streams_.get(),
                   p_streams_mtx_.get(), p_match_.get(), p_hr_start_lck_.get(),
                   p_hr_start_cv_.get(), p_hr_terminable_.get());

    std::thread hp_thread(&HostProducer::Run, &hp);
    std::thread hr_thread(&HostReducer::Run, &hr);
    auto prepare_end_time = std::chrono::system_clock::now();

    hp_thread.join();
    hr_thread.join();

    auto end_time = std::chrono::system_clock::now();

    std::cout << "HyperBlocker.Run() elapsed: "
              << std::chrono::duration_cast<std::chrono::microseconds>(
                     end_time - start_time)
                         .count() /
                     (double)CLOCKS_PER_SEC
              << std::endl;
  }

  void ShowDeviceProperties() {
    cudaError_t cudaStatus;
    std::cout << "Device properties" << std::endl;
    int dev = 0;
    cudaDeviceProp devProp;
    cudaStatus = cudaGetDeviceCount(&dev);
    printf("error %d\n", cudaStatus);
    // if (cudaStatus) return;
    for (int i = 0; i < dev; i++) {
      cudaGetDeviceProperties(&devProp, i);
      std::cout << "Device " << dev << ": " << devProp.name << std::endl;
      std::cout << "multiProcessorCount: " << devProp.multiProcessorCount
                << std::endl;
      std::cout << "sharedMemPerBlock: " << devProp.sharedMemPerBlock / 1024.0
                << " KB" << std::endl;
      std::cout << "maxThreadsPerBlock：" << devProp.maxThreadsPerBlock
                << std::endl;
      std::cout << "maxThreadsPerMultiProcessor："
                << devProp.maxThreadsPerMultiProcessor << std::endl;
      std::cout << std::endl;
    }
    std::cout << "n_device_: " << n_device_ << std::endl;
  }

  void Init() {
    cudaError_t cudaStatus;
    int dev = 0;
    cudaStatus = cudaGetDeviceCount(&dev);
    n_device_ = dev;
  }

  std::vector<Rule> rule_vec_;

private:
  int n_device_ = 1;

  const std::string rule_dir_;
  const std::string data_path_l_;
  const std::string data_path_r_;
  const std::string output_path_;

  const int n_partitions_;
  const int prefix_hash_predicate_index_;

  std::unique_ptr<std::mutex> p_streams_mtx_;

  std::unique_ptr<std::mutex> p_hr_start_mtx_;
  std::unique_ptr<std::unique_lock<std::mutex>> p_hr_start_lck_;
  std::unique_ptr<std::condition_variable> p_hr_start_cv_;

  std::unique_ptr<ExecutionPlanGenerator> epg_;
  std::unique_ptr<DataMngr> data_mngr_;
  std::unique_ptr<std::unordered_map<int, cudaStream_t *>> streams_;

  std::unique_ptr<components::scheduler::Scheduler> scheduler_;
  std::unique_ptr<Match> p_match_;

  std::unique_ptr<bool> p_hr_terminable_;
};

} // namespace core
} // namespace hyperblocker
} // namespace sics
#endif // HYPERBLOCKER_CORE_HYPER_BLOCKER_CUH_
