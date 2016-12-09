defmodule Machine.Adapters.CloudForest.Backtest do
  @moduledoc """
  A module for backtesting the data.
  """

  alias Experimental.Flow
  alias Machine.Corr
  alias Machine.Adapters.CloudForest.{Predictor, Trainer}
  alias Utils.TimeDiff

  @filters Application.get_env(:machine, :corr_filters)
  @data_storage_path Application.get_env(:machine, :data_storage_path)
  @ev_threshold 0.003
  @pft_threshold 0.003
  @stages_num 4
  @annual_k15_count 365 * 24 * 60 / 15
  @seq_names ~w(gt_threshold gt_0 exp_1)a

  @doc """
  Backtests for one.
  """
  def test_one(dir_path, [%{d_la: d_la, time: time, id: label}|target_tl] =
               target_chunk, chunks, opts) do
    filters = Keyword.get(opts, :filters, @filters)
    pattern = Enum.map(target_tl, & &1.d_la)
    time = to_utc_time(time)
    corr_chunks = Corr.find_corr_chunks(chunks, pattern, :d_la)
    case Corr.filter_corr_chunks(corr_chunks, filters) do
      {:ok, logs, filtered} ->
        Trainer.save_data(dir_path, filtered |> Stream.map(& elem(&1, 0)))
        Trainer.learn(dir_path)
        Predictor.save_data(dir_path, target_chunk)
        Predictor.predict(dir_path)
        {:ok, logs, Predictor.read_prediction(dir_path), time}
      {:error, logs} ->
        {:error, logs, {label, nil, d_la}, time}
    end
  end

  @doc """
  Backtests for all.
  """
  def test_all(target_chunks, lookup_chunks, opts \\ []) do
    {measure_time?, opts} = Keyword.pop(opts, :tc, true)
    {cleanup?, opts} = Keyword.pop(opts, :cleanup, true)
    chunk_ranges = validate_chunk_ranges(target_chunks, lookup_chunks)
    data_dir_path = make_data_dir
    fun = fn ->
      ret =
        do_test_all(data_dir_path, target_chunks, lookup_chunks, opts)
        |> Keyword.put(:ranges, chunk_ranges)
      if cleanup? do
        spawn_link(fn -> cleanup_builds(data_dir_path) end)
      end
      ret
    end
    if measure_time? do
      {time, value} = :timer.tc(fun)
      Keyword.put(value, :time_elapsed, floor(time / 1.0e6, 1))
    else
      fun.()
    end
  end

  defp cleanup_builds(data_dir_path) do
    data_dir_path |> get_build_path |> File.rm_rf!
  end

  defp validate_chunk_ranges(target_chunks, lookup_chunks) do
    range = fn chunks ->
      {List.last(List.last(chunks)).time |> to_utc_time,
       hd(hd(chunks)).time |> to_utc_time,
       Enum.count(chunks)}
    end
    {_, lookup_end_time, _} = lookup_range = range.(lookup_chunks)
    {target_start_time, _, _} = target_range = range.(target_chunks)
    if TimeDiff.compare(lookup_end_time, target_start_time,
                        nil, :minutes) >= 0 do
      raise ArgumentError, message: "Target and lookup chunks overlap"
    end
    [lookups: lookup_range, target: target_range]
  end

  defp do_test_all(data_dir_path, target_chunks, lookup_chunks, opts) do
    build_path = get_build_path(data_dir_path)
    File.mkdir!(build_path)
    target_chunks_count = Enum.count(target_chunks)
    result =
      target_chunks
      |> Stream.with_index
      |> Flow.from_enumerable
      |> Flow.partition(stages: @stages_num)
      |> Flow.map(fn {target, index} ->
        IO.puts "---- #{index}..#{target_chunks_count - 1} ----"
        subdir_path = Path.join(build_path, Integer.to_string(index))
        File.mkdir!(subdir_path)
        test_one(subdir_path, target, lookup_chunks, opts) |> IO.inspect
      end)
      |> Enum.sort_by(fn {_, _, _, time} -> time end,
                      & TimeDiff.compare(&1, &2, nil, :seconds) <= 0)
    p_a_list = Enum.filter_map(result, & elem(&1, 0) == :ok,
                 fn {:ok, _, {_, p, a}, _} -> {p, a} end)
    all_samples_pft =
      target_chunks
      |> Enum.reduce(1, fn chunk, acc ->
        (hd(chunk).d_la + 1) * acc
      end)
      |> (& {floor(&1 - 1), target_chunks_count}).()

    {seq_pfts, seq_lists} = test_sequence_pfts(result, target_chunks_count)

    pfts =
      seq_pfts ++
      [gt_threshold: pft(p_a_list),
       gt_0: pft(p_a_list, & &1 > 0),
       lt_0: pft(p_a_list, & &1 < 0),
       all_learned: pft(p_a_list, fn _ -> true end),
       all_samples: all_samples_pft]

    annual_scale = safe_div(@annual_k15_count, target_chunks_count)
    annual_pft = Enum.map(pfts, fn {key, {rate, _count}} ->
      1 + rate
      |> :math.pow(annual_scale)
      |> (& {key, floor(&1 - 1, 1)}).()
    end)

    pft_spectrum = get_pft_spectrum(p_a_list)
    [result: result, p_a_list: p_a_list, pft_spectrum: pft_spectrum,
     corr_filters: get_corr_filters_stats(result),
     stats: [target_chunks_count: target_chunks_count],
     pft_min_max: Enum.min_max_by(pft_spectrum, & elem(&1, 2)),
     annual_pft: annual_pft, seq: seq_lists, pfts: pfts]
    |> Keyword.update!(:stats, & Keyword.merge(&1, count_ev(p_a_list)))
  end

  defp get_build_path(data_dir_path) do
    Path.join(data_dir_path, "build")
  end

  defp test_sequence_pfts(result, target_chunks_count,
                          seq_names \\ @seq_names) do
    {seq_pfts, seq_lists} =
      seq_names
      |> Enum.map(fn atom ->
        sequence_pft(result, p_fun: & seq_p_fun(atom, &1))
      end)
      |> Enum.unzip
    seq_pfts =
      seq_names
      |> Enum.map(& :"seq_#{&1}")
      |> Enum.zip(Enum.map(seq_pfts, & {&1, target_chunks_count}))
    seq_lists = Enum.zip(seq_names, seq_lists)
    {seq_pfts, seq_lists}
  end

  @doc """
  Calculates the decisions and pft expection for the `result` sequence returned
  by `test_all/3` in *chronological* order.
  """
  def sequence_pft(result, opts \\ []) do
    p_fun = opts[:p_fun] || & seq_p_fun(:gt_0, &1)
    initial_ba = opts[:initial_ba] || 1.0
    initial_la = opts[:initial_ba] || 1.0
    slice_rate = opts[:slice_rate] || 0.1
    least_b_partial_scale = opts[:least_b_partial_scale] || 0.001
    slice = initial_ba * slice_rate
    least_b_partial = initial_ba * least_b_partial_scale
    calc_pft = fn holds, ba, la ->
      floor((ba + holds * la) / initial_ba - 1)
    end
    {seq_list, {holds, ba, la}} =
      Enum.map_reduce(result, {0, initial_ba, initial_la},
                  fn {_, _, {_, p, a}, _}, {holds, ba, la} ->
        next_la = la * (1 + a)
        remain = {holds, ba, next_la}
        decision = p_fun.(p)
        log_state = fn decision ->
          {decision, floor(holds), floor(ba), floor(la),
           calc_pft.(holds, ba, la)}
        end
        on = fn exp, value_fun ->
          if exp do
            {log_state.(decision), value_fun.()}
          else
            {log_state.({:remain, decision}), remain}
          end
        end
        case decision do
          :bi_slice ->
            on.(ba >= slice, fn ->
              {holds + slice / la, ba - slice, next_la}
            end)
          :of_slice ->
            h_slice = slice / la
            on.(holds >= h_slice, fn ->
              {holds - h_slice, ba + slice, next_la}
            end)
          :bi_all ->
            on.(ba > 0, fn ->
              {holds + ba / la, 0, next_la}
            end)
          :of_all ->
            on.(holds > 0, fn ->
              {0, ba + holds * la, next_la}
            end)
          {:bi_partial, b_partial_scale} ->
            b_partial = ba * b_partial_scale
            on.(b_partial >= least_b_partial, fn ->
              {holds + b_partial / la, ba - b_partial, next_la}
            end)
          {:of_partial, h_partial_scale} ->
            h_partial = holds * h_partial_scale
            on.(h_partial * la >= least_b_partial, fn ->
              {holds - h_partial, ba + h_partial * la, next_la}
            end)
          {:remain, _} ->
            {log_state.(decision), remain}
        end
      end)
    {calc_pft.(holds, ba, la), seq_list}
  end

  defp seq_p_fun(:gt_threshold, p) do
    cond do
      is_nil(p) ->
        {:of_partial, 0.8}
      p >= @pft_threshold ->
        :bi_all
      p > 0 ->
        {:remain, :"p>0"}
      true ->
        :of_all
    end
  end

  defp seq_p_fun(:gt_0, p) do
    cond do
      is_nil(p) ->
        {:of_partial, 0.8}
      p > 0 ->
        :bi_all
      true ->
        :of_all
    end
  end

  defp seq_p_fun(:exp_1, p) do
    cond do
      is_nil(p) ->
        {:of_partial, 0.8}
      p > 0 ->
        :bi_slice
      true ->
        :of_slice
    end
  end

  defp make_data_dir do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time
    path = Path.join(@data_storage_path, "#{y}-#{m}-#{d}-#{hh}-#{mm}-#{ss}")
    File.mkdir!(path)
    path
  end

  @doc """
  Counts expection values.
  """
  def count_ev(p_a_list, calc_ev_fun \\ &calc_ev/2) do
    expections = Enum.map(p_a_list, fn {p, a} -> calc_ev_fun.(p, a) end)
    count = fn n -> expections |> Stream.filter(& &1 == n) |> Enum.count end
    pos_count = count.(1)
    neg_count = count.(-1)
    zero_count = count.(0)
    [pos_count: pos_count,
     neg_count: neg_count,
     zero_count: zero_count,
     rate: safe_div(pos_count, (pos_count + neg_count))]
  end

  @doc """
  Calculates the pft expectation given the prediction value filter `p_fun`.
  """
  def pft(p_a_list, p_fun \\ &(&1 >= @pft_threshold)) do
    p_a_list
    |> Enum.filter(fn {p, _} -> p_fun.(p) end)
    |> Enum.reduce({1, 0}, fn {_, a}, {value, count} ->
      {value * (1 + a), count + 1}
    end)
    |> (fn {value, count} -> {floor(value - 1), count} end).()
  end

  def get_pft_spectrum(p_a_list) do
    reduce = fn {p, a}, {list, value, count, pos_pft_count} -> 
      value = value * (1 + a)
      pft = value - 1
      count = count + 1
      pos_pft_count =
        if pft > 0 do
          pos_pft_count + 1
        else
          pos_pft_count
        end
      pos_pft_rate = safe_div(pos_pft_count, count)
      {[{p, a, floor(pft), count, pos_pft_count, pos_pft_rate}|list],
       value, count, pos_pft_count}
    end
    p_a_list
    |> Enum.sort_by(fn {p, _} -> p end, &>=/2)
    |> Enum.reduce({[], 1, 0, 0}, reduce)
    |> (& elem(&1, 0)).()
    |> Enum.sort_by(& elem(&1, 0), &>=/2)
  end

  defp get_corr_filters_stats(result) do
    result
    |> Enum.flat_map(fn {_atom, logs, _values, _time} -> logs end)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.update(acc, k, {0, 0}, fn {sum, n} -> {sum + v, n + 1} end)
    end)
    |> Enum.map(fn {k, {sum, n}} -> {k, safe_div(sum, n, 1)} end)
  end

  defp safe_div(a, b, precision \\ 6) do
    if b == 0 do
      :na
    else
      Float.round(a / b, precision)
    end
  end

  defp calc_ev(predicted, actual, threshold \\ @ev_threshold) do
    cond do
      predicted >= threshold && actual >= 0 ->
        1
      predicted >= threshold ->
        -1
      predicted < -threshold && actual < 0 ->
        1
      predicted < -threshold ->
        -1
      true ->
        0
    end
  end

  defp floor(number, precision \\ 6)
  defp floor(number, _) when is_integer(number), do: number
  defp floor(number, precision), do: Float.floor(number, precision)

  defp to_utc_time(time), do: Ecto.DateTime.to_iso8601(time) <> "Z"
end
