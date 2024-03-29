module DistributedQuery
include("DQUtilities.jl")
using Distributed
using DataFrames
using CSV

"""

    deployDataStore(data_worker_pool, worker_func, params=nothing)

deployDataStore takes a function and its parameters and deploys it to each worker in the the data_worker_pool. The results of each worker are assigned to DistributedQuery.DataContainer for later reference and a dictionary of futures of the results is instantly returned.

# Arguments
- `data_worker_pool::Any`: Array of worker ids that each of the data partitions will be placed on
- `worker_func::Any`: The function to be deployed on each worker
- `params` : Optional array of parameters to be passed to the worker_func 

# Returns
- `Dict{Any, Future}`: Returns a Ditionary with worker id as the key, and Future of the spawend deserialize task

"""
function deployDataStore(data_worker_pool, worker_func, params=nothing)
    fut = Dict()
    for dw in data_worker_pool
        if params != nothing
            _fut = @spawnat dw global DataContainer = worker_func(params...)    
        else
            _fut = @spawnat dw global DataContainer = worker_func()
        end
        push!(fut, dw => _fut)
    end
    return fut
end

"""

    sentinel(DataContainer, q_channel, res_channel_dict, status_chan)

`sentinel()` waits for a item to be put on the q_channel.

The item put in `q_channel` should either be a `String` with the message `"Done"`, which will cause `sentinel()` to exit it's  while loop and return or the following **Query Dict**.

- **Query Dict**: this Dict will contain 3 keys: `"query_f"`, `"query_args"`, and `"client"`. The primary function of `sentinel()` is to call, `q_res = query_req["query_f"](DataContainer, query_req["query_args"]...)` and place the result `q_res` in `res_channel_dict[query_req["client"]]`

# Arguments
- `DataContainer::Any`: This should be a container. In typical usage it'll be a DataFrame that was loaded from deployDataStore()
- `q_channel::Channel`: A single channel that will take!() wait for a query dict to be put!() on it.
- `res_channel_dict::Dict{Any, Channel}`: Indexed by worker id. Will be used to look up which channel to place query result on
- `status_chan::Channel`: Status Messages are put!() on this channel

# Returns
- `Nothing`

# Throws
- `Nothing`
"""
function sentinel(DataContainer, q_channel, res_channel_dict, status_chan)
    stat_dict = Dict("message" => "In sentinel",
                     "t_idx" => 1,
                     "myid()" => myid())
    put!(status_chan, stat_dict)

    query_failed = false
    while true
        stat_dict["message"] = """In sentinel, waiting for take """*
            """on channel $(q_channel)"""
        put!(status_chan, stat_dict)
        query_req = take!(q_channel)
        stat_dict["message"] = "In sentinel, got take"
        put!(status_chan, stat_dict)
        if query_req == "Done"
            stat_dict["message"] = "In sentinel, break-ing"
            put!(status_chan, stat_dict)
            break
        end
        stat_dict["message"] = "In sentinel, query_f-ing"
        put!(status_chan, stat_dict)
        try
            query_f = query_req["query_f"]
            global q_res = Base.invokelatest(query_f, DataContainer, query_req["query_args"]...)
        catch e
            query_failed = true
            stat_dict["message"] = "In sentinel, catching error. e: $(e)"
            put!(status_chan, stat_dict)
            put!(res_channel_dict[query_req["client"]], e)
        end
        if !query_failed
            stat_dict["message"] = "In sentinel, putting-ing"
            put!(status_chan, stat_dict)
            put!(res_channel_dict[query_req["client"]], q_res)
            query_failed = false
        end
        GC.gc()
    end
    stat_dict["message"] = "Final Exit"
    put!(status_chan, stat_dict)
end


"""

    function query_client(q_channels, res_channel_dict, agrigate_f, query_f, query_args...)

This function is to submit the query to all the data worker, block until the remote queries come back, then apply the agrigation function to all the results.


# Throws
- `Array{Excpetion}`
"""
function query_client(q_channels, res_channel_dict, agrigate_f, query_f, query_args...)
    query_req = Dict("client" => myid(),
                     "query_f" => query_f,
                     "query_args" => query_args)
    for chan ∈ values(q_channels)
        put!(chan, query_req)
    end
    res_list = []

    for i ∈ 1:length(q_channels)
        res = take!(res_channel_dict)
        push!(res_list, res)
    end
    except_mask = [typeof(r) <: Exception for r in res_list]
    if any(except_mask)
        zipped_id_errors = collect(zip(["Error on worker $(c[1])" for c in q_channels], res_list))
        throw([zipped_id_errors[except_mask]])
    end
    res = agrigate_f(res_list...)
    return res
end


function make_query_channels(data_worker_pool, proc_worker_pool, chan_depth::Int=5)
    proc_chan = Dict(p => RemoteChannel(()->Channel{Any}(chan_depth), p) for p ∈ proc_worker_pool)
    data_chan = Dict(p => RemoteChannel(()->Channel{Any}(chan_depth), p) for p ∈ data_worker_pool)
    return proc_chan, data_chan
end

end # module DistributedQuery
