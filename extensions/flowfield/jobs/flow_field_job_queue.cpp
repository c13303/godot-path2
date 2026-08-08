#include "flow_field_job_queue.h"


namespace ffcore
{
    FlowFieldJobQueue::FlowFieldJobQueue() : worker(&FlowFieldJobQueue::worker_loop, this) {}

    FlowFieldJobQueue::~FlowFieldJobQueue()
    {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopping = true;
            pending.clear();
        }
        condition.notify_all();
        if (worker.joinable())
            worker.join();
    }

    std::uint64_t FlowFieldJobQueue::submit(
        const FlowFieldBuildRequest &request,
        std::uint64_t topology_revision,
        std::uint64_t cost_revision)
    {
        std::lock_guard<std::mutex> lock(mutex);
        const std::uint64_t id = next_request_id++;
        pending.push_back({id, topology_revision, cost_revision, request});
        condition.notify_one();
        return id;
    }

    void FlowFieldJobQueue::cancel(std::uint64_t request_id)
    {
        std::lock_guard<std::mutex> lock(mutex);
        cancelled.insert(request_id);
        for (auto iterator = pending.begin(); iterator != pending.end();)
        {
            if (iterator->id == request_id)
                iterator = pending.erase(iterator);
            else
                ++iterator;
        }
        for (auto iterator = completed.begin(); iterator != completed.end();)
        {
            if (iterator->request_id == request_id)
                iterator = completed.erase(iterator);
            else
                ++iterator;
        }
    }

    bool FlowFieldJobQueue::take_completed(FlowFieldJobResult &result)
    {
        std::lock_guard<std::mutex> lock(mutex);
        while (!completed.empty())
        {
            const FlowFieldJobResult &front = completed.front();
            result.request_id = front.request_id;
            result.topology_revision = front.topology_revision;
            result.cost_revision = front.cost_revision;
            result.build.ok = front.build.ok;
            result.build.field.copy_from(front.build.field);
            completed.pop_front();
            if (cancelled.erase(result.request_id) == 0)
                return true;
        }
        return false;
    }

    bool FlowFieldJobQueue::is_idle() const
    {
        std::lock_guard<std::mutex> lock(mutex);
        return pending.empty() && completed.empty() && !active;
    }

    void FlowFieldJobQueue::worker_loop()
    {
        while (true)
        {
            Request request;
            {
                std::unique_lock<std::mutex> lock(mutex);
                condition.wait(lock, [&]() { return stopping || !pending.empty(); });
                if (stopping)
                    return;
                request = pending.front();
                pending.pop_front();
                active = true;
            }

            FlowFieldJobResult result;
            result.request_id = request.id;
            result.topology_revision = request.topology_revision;
            result.cost_revision = request.cost_revision;
            result.build = FlowFieldBuilder::build(request.build);
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (cancelled.erase(request.id) == 0)
                    completed.push_back(result);
                active = false;
            }
        }
    }
} // namespace ffcore
