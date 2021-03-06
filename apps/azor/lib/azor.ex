defmodule Azor do
  use Application
  alias Azor.Ords.{Manager, WatcherSupervisor}

  @simple_handler   Azor.Handlers.Simple.AfterFetch
  @handlers_watcher Azor.Handlers.Watcher

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Manager, [%{}, [name: Manager]]),
      supervisor(WatcherSupervisor, [[name: WatcherSupervisor]],
                 restart: :permanent),
      worker(@handlers_watcher,
             handlers_watcher_args(:simple, @simple_handler))
    ]

    opts = [strategy: :rest_for_one, name: Azor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp handlers_watcher_args(mode, handler) do
    [%{mode: mode, handler: handler}, [name: @handlers_watcher]]
  end
end
