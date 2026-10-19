defmodule GlacierRelay.Motion.Course do
  @moduledoc """
  M7-B1: one small deterministic generator of synthetic courses (`docs/design/M7_NETWORK_GHOST.md`
  sections 14 and 15.9) — offline fixtures, never real-player samples, never a locomotion
  demonstration, never a cleared route. No pathfinding: a course is an origin and a list of
  segments — `{:hold, ms}`, `{:line, {x, y}}` (straight, from the current position), `{:arc,
  {cx, cy}, sweep_rad}` (around a centre, from the current position; a positive sweep is
  counter-clockwise seen from +z with x east and y north) — walked at one constant speed (the
  speed policy; holds are stationary; a corner changes direction, never position).

  Every profile **starts with a stationary hold at the origin** (the session's anchor P), reaches
  its start by an explicit `line` and returns to the origin by one, so acquisition, transitions and
  the closing segment are inside the same checks as the rest. Sample `k` (sequence number `k + 1`)
  is the path position at `k × interval_ms`; samples run to the end of the final hold. Positions
  are rounded to binary32 words (`Command.TransformWords`); the origin is given as its exact words,
  so the first sample equals the anchor exactly.

  Profiles: `out_and_back/2`, `shuttle/2`, `rectangle/2`, `figure_eight/2` (two lobes through one
  crossing, opposite senses, so the heading is continuous at the crossing), `circle/2`. Each takes
  a `:direction` (`:forward` / `:reverse`). `check/2` verifies a course against limits offline.
  """

  alias GlacierRelay.Command.TransformWords

  @two_pi 2 * :math.pi()

  defstruct [:name, :origin, :origin_words, :z_word, :interval_ms, :speed_mps, :params, :segments]

  @doc """
  A course from explicit segments. `opts`: `:origin_words` (`{x_word, y_word}`, required), `:z_word`
  (the constant z word carried in `pos` for evidence; default the origin's 0.0 word), `:interval_ms`
  (50), `:speed_mps` (> 0), `:name`, `:params` (recorded).
  """
  def build(segments, opts) when is_list(segments) do
    {xw, yw} = Keyword.fetch!(opts, :origin_words)
    speed = Keyword.fetch!(opts, :speed_mps)
    true = is_number(speed) and speed > 0
    interval = Keyword.get(opts, :interval_ms, 50)
    true = is_integer(interval) and interval >= 50

    %__MODULE__{
      name: Keyword.get(opts, :name, "custom"),
      origin: {TransformWords.to_float(xw), TransformWords.to_float(yw)},
      origin_words: {xw, yw},
      z_word: Keyword.get(opts, :z_word, 0),
      interval_ms: interval,
      speed_mps: speed * 1.0,
      params: Keyword.get(opts, :params, %{}),
      segments: segments
    }
  end

  @doc """
  Out and back from the origin: a stationary prefix, `:distance_m` out along `:heading_rad` (0 =
  +x), a hold, back to the origin, a final hold. Defaults: 1.0 m, 0.5 m/s, heading 0, prefix and
  holds 2,000 ms. The recommended first destination course (section 15.9) — not a permission.
  """
  def out_and_back(origin_words, opts \\ []) do
    d = Keyword.get(opts, :distance_m, 1.0)
    heading = Keyword.get(opts, :heading_rad, 0.0) + if(reverse?(opts), do: :math.pi(), else: 0.0)
    {ox, oy} = floats(origin_words)
    far = {ox + d * :math.cos(heading), oy + d * :math.sin(heading)}
    hold = Keyword.get(opts, :hold_ms, 2_000)

    build(
      [
        {:hold, Keyword.get(opts, :prefix_ms, 2_000)},
        {:line, far},
        {:hold, hold},
        {:line, {ox, oy}},
        {:hold, hold}
      ],
      common(opts, origin_words, "out_and_back", %{distance_m: d, heading_rad: heading}, 0.5)
    )
  end

  @doc """
  Back and forth between two points `:a` and `:b`: prefix, origin → first end, `:laps` there-and-
  back legs, last end → origin, final hold. `:reverse` starts toward `:b`.
  """
  def shuttle(origin_words, opts) do
    a = Keyword.fetch!(opts, :a)
    b = Keyword.fetch!(opts, :b)
    {first, second} = if reverse?(opts), do: {b, a}, else: {a, b}
    laps = Keyword.get(opts, :laps, 1)
    origin = floats(origin_words)

    legs = Enum.flat_map(1..laps, fn _ -> [{:line, second}, {:line, first}] end)

    build(
      [{:hold, Keyword.get(opts, :prefix_ms, 2_000)}, {:line, first}] ++
        legs ++ [{:line, origin}, {:hold, Keyword.get(opts, :hold_ms, 2_000)}],
      common(opts, origin_words, "shuttle", %{a: a, b: b, laps: laps}, 1.0)
    )
  end

  @doc """
  A rectangle `:x` = `{x_min, x_max}`, `:y` = `{y_min, y_max}` (a square when equal sides): prefix,
  straight from the origin to the south edge at the origin's x (an explicit transition; the origin's
  x must lie inside `:x`), `:laps` circuits counter-clockwise (`:forward`) or clockwise
  (`:reverse`), back to the origin, final hold.
  """
  def rectangle(origin_words, opts) do
    {x0, x1} = Keyword.fetch!(opts, :x)
    {y0, y1} = Keyword.fetch!(opts, :y)
    {ox, oy} = floats(origin_words)
    true = ox > x0 and ox < x1 and x0 < x1 and y0 < y1
    entry = {ox, y0}

    corners =
      if reverse?(opts),
        do: [{x0, y0}, {x0, y1}, {x1, y1}, {x1, y0}, entry],
        else: [{x1, y0}, {x1, y1}, {x0, y1}, {x0, y0}, entry]

    laps = Keyword.get(opts, :laps, 1)
    circuit = Enum.flat_map(1..laps, fn _ -> Enum.map(corners, &{:line, &1}) end)

    build(
      [{:hold, Keyword.get(opts, :prefix_ms, 2_000)}, {:line, entry}] ++
        circuit ++ [{:line, {ox, oy}}, {:hold, Keyword.get(opts, :hold_ms, 2_000)}],
      common(opts, origin_words, "rectangle", %{x: {x0, x1}, y: {y0, y1}, laps: laps}, 1.0)
    )
  end

  @doc """
  A figure-eight of two lobes centred on `:c1` and `:c2` meeting at their midpoint (the crossing,
  which is not the origin): prefix, origin → crossing, `:loops` × (a full turn around `:c1`, then a
  full turn around `:c2` in the opposite sense — the heading is continuous at the crossing), back to
  the origin, final hold. `:forward` turns clockwise around `:c1`; `:reverse` counter-clockwise.
  """
  def figure_eight(origin_words, opts) do
    {c1x, c1y} = c1 = Keyword.fetch!(opts, :c1)
    {c2x, c2y} = c2 = Keyword.fetch!(opts, :c2)
    crossing = {(c1x + c2x) / 2, (c1y + c2y) / 2}
    sense = if reverse?(opts), do: 1, else: -1
    loops = Keyword.get(opts, :loops, 1)

    lobes =
      Enum.flat_map(1..loops, fn _ ->
        [{:arc, c1, sense * @two_pi}, {:arc, c2, -sense * @two_pi}]
      end)

    build(
      [{:hold, Keyword.get(opts, :prefix_ms, 2_000)}, {:line, crossing}] ++
        lobes ++ [{:line, floats(origin_words)}, {:hold, Keyword.get(opts, :hold_ms, 2_000)}],
      common(opts, origin_words, "figure_eight", %{c1: c1, c2: c2, loops: loops}, 1.0)
    )
  end

  @doc """
  A circle around `:center` with `:radius_m`: prefix, origin → the circle's point nearest the
  origin, `:laps` turns counter-clockwise (`:forward`) or clockwise (`:reverse`), back, final hold.
  The fountain-style profile (its real geometry is not known; section 15.9).
  """
  def circle(origin_words, opts) do
    {cx, cy} = center = Keyword.fetch!(opts, :center)
    r = Keyword.fetch!(opts, :radius_m)
    {ox, oy} = origin = floats(origin_words)
    dist = :math.sqrt(:math.pow(ox - cx, 2) + :math.pow(oy - cy, 2))
    true = dist > 0
    start = {cx + r * (ox - cx) / dist, cy + r * (oy - cy) / dist}
    laps = Keyword.get(opts, :laps, 1)
    sense = if reverse?(opts), do: -1, else: 1

    build(
      [
        {:hold, Keyword.get(opts, :prefix_ms, 2_000)},
        {:line, start},
        {:arc, center, sense * laps * @two_pi},
        {:line, origin},
        {:hold, Keyword.get(opts, :hold_ms, 2_000)}
      ],
      common(opts, origin_words, "circle", %{center: center, radius_m: r, laps: laps}, 1.0)
    )
  end

  defp common(opts, origin_words, name, params, default_speed) do
    [
      origin_words: origin_words,
      z_word: Keyword.get(opts, :z_word, 0),
      interval_ms: Keyword.get(opts, :interval_ms, 50),
      speed_mps: Keyword.get(opts, :speed_mps, default_speed),
      name: name,
      params:
        Map.merge(params, %{
          direction: if(reverse?(opts), do: :reverse, else: :forward),
          prefix_ms: Keyword.get(opts, :prefix_ms, 2_000),
          hold_ms: Keyword.get(opts, :hold_ms, 2_000)
        })
    ]
  end

  defp reverse?(opts), do: Keyword.get(opts, :direction, :forward) == :reverse
  defp floats({xw, yw}), do: {TransformWords.to_float(xw), TransformWords.to_float(yw)}

  # -- timing ---------------------------------------------------------------------------------------

  # the segments with their start position, end position, start time and duration (ms, float)
  defp timeline(%__MODULE__{} = c) do
    {pieces, _pos, _t} =
      Enum.reduce(c.segments, {[], c.origin, 0.0}, fn seg, {acc, pos, t} ->
        {finish, dur} = extent(seg, pos, c.speed_mps)
        {[{seg, pos, finish, t, dur} | acc], finish, t + dur}
      end)

    Enum.reverse(pieces)
  end

  defp extent({:hold, ms}, pos, _v), do: {pos, ms * 1.0}

  defp extent({:line, {bx, by} = b}, {ax, ay}, v),
    do: {b, :math.sqrt(:math.pow(bx - ax, 2) + :math.pow(by - ay, 2)) / v * 1_000}

  defp extent({:arc, {cx, cy}, sweep}, {ax, ay}, v) do
    r = :math.sqrt(:math.pow(ax - cx, 2) + :math.pow(ay - cy, 2))
    theta = :math.atan2(ay - cy, ax - cx) + sweep
    {{cx + r * :math.cos(theta), cy + r * :math.sin(theta)}, abs(sweep) * r / v * 1_000}
  end

  defp at({:hold, _}, start, _finish, _frac), do: start

  defp at({:line, _}, {ax, ay}, {bx, by}, frac),
    do: {ax + (bx - ax) * frac, ay + (by - ay) * frac}

  defp at({:arc, {cx, cy}, sweep}, {ax, ay}, _finish, frac) do
    r = :math.sqrt(:math.pow(ax - cx, 2) + :math.pow(ay - cy, 2))
    theta = :math.atan2(ay - cy, ax - cx) + sweep * frac
    {cx + r * :math.cos(theta), cy + r * :math.sin(theta)}
  end

  @doc "The course's total duration (ms)."
  def duration_ms(%__MODULE__{} = c) do
    case List.last(timeline(c)) do
      nil -> 0.0
      {_seg, _a, _b, t, dur} -> t + dur
    end
  end

  @doc """
  The samples, deterministic: `%{seq, t_ms, x, y, x_word, y_word, pos}` for `k` = 0 … ⌊duration /
  interval⌋ (sequence number `k + 1`, `t_ms = k × interval_ms`); `pos` is the `x,y,z` word text of a
  `pose.sample`. Sample 1 is the origin's exact words.
  """
  def samples(%__MODULE__{} = c) do
    tl = timeline(c)
    total = duration_ms(c)
    n = trunc(total / c.interval_ms)

    for k <- 0..n do
      t = k * c.interval_ms
      {xw, yw} = if k == 0, do: c.origin_words, else: words(position(tl, t))

      %{
        seq: k + 1,
        t_ms: t,
        x: TransformWords.to_float(xw),
        y: TransformWords.to_float(yw),
        x_word: xw,
        y_word: yw,
        pos: TransformWords.encode([xw, yw, c.z_word])
      }
    end
  end

  defp position(tl, t) do
    case Enum.find(tl, fn {_s, _a, _b, t0, dur} -> t < t0 + dur end) do
      {seg, a, b, t0, dur} -> at(seg, a, b, if(dur > 0, do: (t - t0) / dur, else: 1.0))
      nil -> tl |> List.last() |> elem(2)
    end
  end

  defp words({x, y}), do: {TransformWords.to_word(x), TransformWords.to_word(y)}

  @doc """
  Checks a course offline against `limits` (`:half_extent_mm`, `:max_speed_mmps` — the session's
  enforced limits, defaults as `Motion.Destination`): every sample inside the origin's area, the
  first sample exactly the origin, every step at most both the course's own speed and the session's
  maximum speed times the interval (binary32 rounding allowed for: 1 mm). Returns `{:ok, stats}` —
  sample count, duration, path length, largest step, bounding box — or `{:error, violations}`
  (the first eight).
  """
  def check(%__MODULE__{} = c, limits \\ %{}) do
    half = Map.get(limits, :half_extent_mm, 8_000) / 1_000
    vmax = Map.get(limits, :max_speed_mmps, 2_000) / 1_000
    {ox, oy} = c.origin
    ss = samples(c)
    step_cap = min(c.speed_mps, vmax) * c.interval_ms / 1_000 + 0.001

    steps =
      ss
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        {b.seq, :math.sqrt(:math.pow(b.x - a.x, 2) + :math.pow(b.y - a.y, 2))}
      end)

    violations =
      Enum.flat_map(ss, fn s ->
        if abs(s.x - ox) <= half and abs(s.y - oy) <= half, do: [], else: [{:outside_area, s.seq}]
      end) ++
        Enum.flat_map(steps, fn {seq, d} -> if d <= step_cap, do: [], else: [{:step, seq, d}] end) ++
        if({hd(ss).x_word, hd(ss).y_word} == c.origin_words,
          do: [],
          else: [:first_sample_not_origin]
        )

    case violations do
      [] ->
        xs = Enum.map(ss, & &1.x)
        ys = Enum.map(ss, & &1.y)

        {:ok,
         %{
           name: c.name,
           samples: length(ss),
           duration_ms: duration_ms(c),
           length_m: steps |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
           max_step_m: steps |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end),
           bbox: {Enum.min(xs), Enum.max(xs), Enum.min(ys), Enum.max(ys)},
           speed_mps: c.speed_mps,
           interval_ms: c.interval_ms
         }}

      v ->
        {:error, Enum.take(v, 8)}
    end
  end

  @doc "A short description for `stream.open`'s `course` field (at most 200 bytes)."
  def describe(%__MODULE__{} = c) do
    params =
      c.params
      |> Enum.sort()
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    text = "#{c.name} v=#{c.speed_mps} i=#{c.interval_ms} #{params}"
    if byte_size(text) <= 200, do: text, else: binary_part(text, 0, 200)
  end
end
