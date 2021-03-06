defmodule Caravan.Wheel.Interval do
  use GenServer
  import Task.Supervisor, only: [start_child: 4]
  alias Caravan.Wheel

  @interval_sup Wheel.Interval.Supervisor
  @pulling_intervals Application.get_env(:caravan, :pulling_intervals)

  @doc """
  Starts Caravan.Wheel.Interval instance.

  ## Options

  - `interval_sup`: The `Task.Supervisor` for supervising periodically
    pulling processes. `Caravan.Wheel.Interval.Supervisor` by default.

  - `wheel`: The wheel instance for pulling. `Caravan.Wheel` by default.

  - `mode`: The mode for pulling. available options: `:simple`, `:k15`.
    `:simple` by default.

  - `pulling_interval`: The interval to trigger pulling. Default values:
    * #{@pulling_intervals.simple} for simple mode,
    * #{@pulling_intervals.k15} for k15 mode.

  - `test_process`: The message monitoring process for testing purposes.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, extract_options(opts))
  end

  defp extract_options(opts) do
    {wheel, opts} = Keyword.pop(opts, :wheel, Wheel)
    {mode, opts} = Keyword.pop(opts, :mode, :simple)
    {interval_sup, opts} = Keyword.pop(opts, :interval_sup, @interval_sup)
    {interval, opts} = Keyword.pop(opts, :pulling_interval,
                                   @pulling_intervals[mode])
    {test_process, _} = Keyword.pop(opts, :test_process, nil)
    %{wheel: wheel,
      mode: mode,
      interval_sup: interval_sup,
      pulling_interval: interval,
      test_process: test_process}
  end

  ## Callbacks

  def init(state) do
    Process.send(self(), :pull, [])
    {:ok, state}
  end

  def handle_info(:pull, %{interval_sup: interval_sup, wheel: wheel,
                           mode: mode, pulling_interval: interval,
                           test_process: test_process} = state) do
    {:ok, pid} = start_child(interval_sup, Wheel, :pull, [wheel, mode])
    if test_process do
      send(test_process, {:start_child, pid})
    end
    Process.send_after(self(), :pull, interval)
    {:noreply, state}
  end
end
