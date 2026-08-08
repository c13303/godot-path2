#pragma once

#include "../flow/flow_field_builder.h"

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_set>

namespace ffcore
{
    struct FlowFieldJobResult
    {
        std::uint64_t request_id = 0;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;
        FlowFieldBuildResult build;
    };

    class FlowFieldJobQueue
    {
    private:
        struct Request
        {
            std::uint64_t id = 0;
            std::uint64_t topology_revision = 0;
            std::uint64_t cost_revision = 0;
            FlowFieldBuildRequest build;
        };

        mutable std::mutex mutex;
        std::condition_variable condition;
        std::deque<Request> pending;
        std::deque<FlowFieldJobResult> completed;
        std::unordered_set<std::uint64_t> cancelled;
        std::thread worker;
        std::uint64_t next_request_id = 1;
        bool stopping = false;
        bool active = false;
        std::uint64_t active_request_id = 0;

        void worker_loop();

    public:
        FlowFieldJobQueue();
        ~FlowFieldJobQueue();
        FlowFieldJobQueue(const FlowFieldJobQueue &) = delete;
        FlowFieldJobQueue &operator=(const FlowFieldJobQueue &) = delete;

        std::uint64_t submit(const FlowFieldBuildRequest &request,
                             std::uint64_t topology_revision,
                             std::uint64_t cost_revision);
        void cancel(std::uint64_t request_id);
        bool take_completed(FlowFieldJobResult &result);
        bool is_idle() const;
    };
} // namespace ffcore
