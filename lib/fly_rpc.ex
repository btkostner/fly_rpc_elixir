defmodule Fly.RPC do
  @moduledoc """
  Provides an RPC interface for executing an MFA on a node within a region.

  ## Configuration

  Assumes each node is running the `Fly.RPC` server in its supervision tree and
  exports `FLY_REGION` environment variable to identify the fly region.

  To run code on a specific region call `rpc_region/4`. A node found within the
  given region will be chosen at random. Raises if no nodes exist on the given
  region.

  The special `:primary` region may be passed to run the rpc against the region
  identified by the `PRIMARY_REGION` environment variable.

  ## Examples

      > rpc_region("hkg", String, :upcase, ["fly"])
      "FLY"

      > rpc_region(Fly.primary_region(), String, :upcase, ["fly"])
      "FLY"

      > rpc_region(:primary, String, :upcase, ["fly"])
      "FLY"

  ## Server

  The GenServer's responsibility is just to monitor other nodes as they enter
  and leave the cluster. It maintains a list of nodes and the Fly.io region
  where they are deployed in an ETS table that other processes can use to find
  and initiate their own RPC calls to.
  """
  use GenServer
  require Logger

  @tab :fly_regions

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the Elixir OTP nodes registered the region. Reads from a local cache.
  """
  def region_nodes(tab \\ @tab, region) do
    case :ets.lookup(tab, region) do
      [{^region, nodes}] -> nodes
      [] -> []
    end
  end

  @doc """
  Asks a node what Fly region it's running in. Does this through an RPC call. If
  the function for asking isn't supported (code not running there yet), return
  an `:error`.
  """
  def region(node) do
    if is_rpc_supported?(node) do
      {:ok, rpc(node, 3_000, Fly, :my_region, [])}
    else
      Logger.info("Detected Fly RPC support is not available on node #{inspect(node)}")
      :error
    end
  end

  def rpc_region(region, module, func, args, opts \\ [])

  def rpc_region(:primary, module, func, args, opts) do
    rpc_region(Fly.primary_region(), module, func, args, opts)
  end

  def rpc_region(region, module, func, args, opts) when is_binary(region) do
    if region == Fly.my_region() do
      apply(module, func, args)
    else
      timeout = Keyword.get(opts, :timeout, 5_000)
      available_nodes = region_nodes(region)

      if Enum.empty?(available_nodes),
        do: raise(ArgumentError, "no node found running in region #{inspect(region)}")

      node = Enum.random(available_nodes)

      rpc(node, timeout, module, func, args)
    end
  end

  @doc """
  Executes the function on the remote node and waits for the response up to
  `timeout` length.
  """
  def rpc(node, timeout, module, func, args) do
    caller = self()
    ref = make_ref()

    # Perform the RPC call to the remote node and wait for the response
    Node.spawn_link(node, __MODULE__, :__local_rpc__, [
      [caller, ref, module, func | args]
    ])

    receive do
      {^ref, result} -> result
    after
      timeout -> exit(:timeout)
    end
  end

  @doc false
  # Private function that can be executed on a remote node in the cluster. Used
  # to execute arbitrary function from a trusted caller.
  def __local_rpc__([caller, ref, module, func | args]) do
    result = apply(module, func, args)
    send(caller, {ref, result})
  end

  @doc """
  Executes a function on the remote node to determine if the RPC API support is
  available.

  Support may not exist on the remote node in a "first roll out" scenario.
  """
  def is_rpc_supported?(node) do
    caller = self()
    ref = make_ref()

    # NOTE: Not using `spawn_link` because on remote hidden nodes like for
    # connecting Observer, there is no `__local_rpc__` function for using at
    # all. This may fail with a timeout in situations like that.
    Node.spawn(node, __MODULE__, :__local_rpc__, [
      [caller, ref, Kernel, :function_exported?, Fly, :my_region, 0]
    ])

    receive do
      {^ref, result} -> result
    after
      1_300 ->
        Logger.warn("Timed out waiting for RPC supported test. Assuming `false`.")
        false
    end
  end

  ## RPC calls run on local node

  def init(_opts) do
    tab = :ets.new(@tab, [:named_table, :public, read_concurrency: true])
    # monitor new node up/down activity
    :global_group.monitor_nodes(true)
    {:ok, %{nodes: MapSet.new(), tab: tab}, {:continue, :get_node_regions}}
  end

  def handle_continue(:get_node_regions, state) do
    new_state =
      Enum.reduce(Node.list(), state, fn node_name, acc ->
        put_node(acc, node_name)
      end)

    {:noreply, new_state}
  end

  def handle_info({:nodeup, node_name}, state) do
    Logger.debug("nodeup #{node_name}")
    {:noreply, put_node(state, node_name)}
  end

  def handle_info({:nodedown, node_name}, state) do
    Logger.debug("nodedown #{node_name}")
    {:noreply, drop_node(state, node_name)}
  end

  # Executed when a new node shows up in the cluster. Asks the node what region
  # it's running in. If the request isn't supported by the node, do nothing.
  # This happens when this node is the first node with this new code. It reaches
  # out to the other nodes (they show up as having just appeared) but they don't
  # yet have the new code. So this ignores that node until it gets new code,
  # restarts and will then again show up as a new node.
  @doc false
  def put_node(state, node_name) do
    case region(node_name) do
      {:ok, region} ->
        region_nodes = region_nodes(state.tab, region)
        :ets.insert(state.tab, {region, [node_name | region_nodes]})

        %{state | nodes: MapSet.put(state.nodes, {node_name, region})}

      :error ->
        state
    end
  end

  @doc false
  def drop_node(state, node_name) do
    # find the node information for the node going down.
    case get_node(state, node_name) do
      {^node_name, region} ->
        # get the list of nodes currently registered in that region
        region_nodes = region_nodes(state.tab, region)
        # Remove the node from the known regions and update the local cache
        new_regions = Enum.reject(region_nodes, fn n -> n == node_name end)
        :ets.insert(state.tab, {region, new_regions})

        # Remove the node entry from the GenServer's state
        new_nodes =
          Enum.reduce(state.nodes, state.nodes, fn
            {^node_name, ^region}, acc -> MapSet.delete(acc, {node_name, region})
            {_node, _region}, acc -> acc
          end)

        # Return the new state
        %{state | nodes: new_nodes}

      # Node is not known to us. Ignore it.
      nil ->
        state
    end
  end

  defp get_node(state, name) do
    Enum.find(state.nodes, fn {n, _region} -> n == name end)
  end
end
