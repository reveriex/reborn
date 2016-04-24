defmodule Caravan do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Caravan.Wheel, [[name: Caravan.Wheel]])
    ]

    opts = [strategy: :one_for_one, name: Caravan.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
