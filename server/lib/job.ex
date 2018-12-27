defmodule OAAS.Job do
  @moduledoc "Jobs are recording/uploading tasks to be completed."

  use Bitwise, only_operators: true

  alias OAAS.DB
  alias OAAS.Worker
  import OAAS.Utils
  require DB

  @doc "Defines the job status enum."
  def status(_s)

  @spec status(atom) :: integer
  def status(:pending), do: 0
  def status(:assigned), do: 1
  def status(:recording), do: 2
  def status(:uploading), do: 3
  def status(:successful), do: 4
  def status(:failed), do: 5
  def status(:deleted), do: 6

  @spec status(integer) :: atom
  def status(0), do: :pending
  def status(1), do: :assigned
  def status(2), do: :recording
  def status(3), do: :uploading
  def status(4), do: :successful
  def status(5), do: :failed
  def status(6), do: :deleted

  @table "jobs"

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :player,
    :beatmap,
    :replay,
    :youtube,
    :skin,
    :status,
    :created_at,
    :updated_at
  ]
  defstruct @enforce_keys ++ [:reddit_id, :comment, :worker_id]

  @type t :: %__MODULE__{
          # Job ID.
          id: integer,
          # Player data: {id, name}.
          player: map,
          # Beatmap data: {id, name, mode}.
          beatmap: map,
          # Replay data: {data, length}.
          replay: map,
          # YouTube upload data: {title, description}.
          youtube: map,
          # Skin to use: {name, url}.
          skin: map,
          # Job status.
          status: integer,
          # Reddit post ID.
          reddit_id: binary | nil,
          # Comment from the worker.
          comment: binary | nil,
          # Assigned worker.
          worker_id: binary | nil,
          # Job creation time.
          created_at: integer,
          # Job update time.
          updated_at: integer
        }

  @json_columns [:player, :beatmap, :replay, :youtube, :skin]

  use OAAS.Model

  @doc "Marks a job as deleted, but leaves it in the database."
  @spec mark_deleted(t) :: {:ok, t} | {:error, term}
  def mark_deleted(%__MODULE__{} = j) do
    DB.transaction do
      unless is_nil(j.worker_id) do
        with {:ok, w} <- Worker.get(j.worker_id),
             {:ok, _} <- Worker.update(w, current_job_id: nil) do
          :noop
        else
          {:error, reason} -> throw(reason)
        end
      end

      case update(j, worker_id: nil, status: status(:deleted)) do
        {:ok, j} -> j
        {:error, reason} -> throw(reason)
      end
    end
  end

  @timeouts %{
    assigned: 90 * 1000,
    recording: 10 * 60 * 1000,
    uploading: 10 * 60 * 1000
  }

  @doc "Gets all jobs which are running but stalled."
  @spec get_stalled :: [t]
  def get_stalled do
    now = System.system_time(:millisecond)

    case query(
           "SELECT * FROM #{@table} WHERE status BETWEEN ?1 AND ?2",
           x: status(:assigned),
           x: status(:uploading)
         ) do
      {:ok, js} ->
        {:ok, Enum.filter(js, fn j -> abs(now - j.updated_at) > @timeouts[status(j.status)] end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Gets all jobs with a given status."
  @spec get_by_status(atom | integer) :: {:ok, [t]} | {:error, term}
  def get_by_status(stat) when is_atom(stat) do
    stat
    |> status()
    |> get_by_status()
  end

  def get_by_status(stat) when is_integer(stat) do
    query("SELECT * FROM #{@table} WHERE status = ?1", x: stat)
  end

  @doc "Assigns a job to a worker."
  @spec assign(t, Worker.t()) :: {:ok, t} | {:error, term}
  def assign(%__MODULE__{} = j, %Worker{} = w) do
    DB.transaction do
      with {:ok, _} <-
             Worker.update(w, current_job_id: j.id, last_job: System.system_time(:millisecond)),
           {:ok, j} <- update(j, worker_id: w.id, status: status(:assigned)) do
        j
      else
        {:error, reason} -> throw(reason)
      end
    end
  end

  @doc "Checks whether a job is finished."
  @spec finished(t) :: boolean
  def finished(%__MODULE__{} = j) do
    j.status >= status(:successful)
  end

  @doc "Updates a job's status."
  @spec update_status(t, Worker.t(), integer, binary) :: {:ok, t} | {:error, term}
  def update_status(%__MODULE__{} = j, %Worker{} = w, stat, comment) do
    DB.transaction do
      case update(j, status: stat, comment: comment) do
        {:ok, j} ->
          if finished(j) do
            case Worker.update(w, current_job_id: nil) do
              {:ok, _w} -> j
              {:error, reason} -> throw(reason)
            end
          else
            j
          end

        {:error, reason} ->
          throw(reason)
      end
    end
  end

  @doc "Fails a job."
  @spec fail(t, binary) :: {:ok, t} | {:error, term}
  def fail(%__MODULE__{} = j, comment \\ "") do
    DB.transaction do
      with {:ok, w} <- Worker.get(j.worker_id),
           {:ok, _w} <- Worker.update(w, current_job_id: nil),
           {:ok, j} <- update(j, worker_id: nil, status: status(:failed), comment: comment) do
        j
      else
        {:error, reason} -> throw(reason)
      end
    end
  end

  @doc "Reschedules a job."
  @spec reschedule(t) :: {:ok, t} | {:error, term}
  def reschedule(%__MODULE__{} = j) do
    unless j.status === status(:failed) do
      notify(:warn, "rescheduling non-failed job #{j.id} (#{status(j.status)})")
    end

    update(j, status: status(:pending))
  end

  @doc "Creates a job from a Reddit post."
  @spec from_reddit(binary, binary) :: {:ok, t} | {:error, term}
  def from_reddit(id, title) do
    with {:ok, username} <- extract_username(title),
         {:ok, map_name} <- extract_map_name(title),
         {:ok, %{} = player} <- OsuEx.API.get_user(username, event_days: 31),
         {:ok, beatmap} <- search_beatmap(player, map_name),
         {:ok, osr} <- get_osr(player, beatmap),
         {:ok, replay} <- OsuEx.Parser.osr(osr) do
      put(
        player: Map.drop(player, [:events]),
        beatmap: beatmap,
        replay: %{data: Base.encode64(osr), length: replay_time(beatmap, replay.mods)},
        youtube: youtube_data(player, beatmap, replay),
        skin: skin(player.username),
        status: status(:pending),
        reddit_id: id
      )
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates a job from a replay link."
  @spec from_osr(binary, binary | nil) :: {:ok, t} | {:error, term}
  def from_osr(url, skin_override \\ nil) do
    with {:ok, %{body: osr}} <- HTTPoison.get(url),
         {:ok, replay} = OsuEx.Parser.osr(osr),
         {:ok, player} = OsuEx.API.get_user(replay.player),
         {:ok, beatmap} = OsuEx.API.get_beatmap(replay.beatmap_md5) do
      put(
        player: Map.drop(player, [:events]),
        beatmap: beatmap,
        replay: %{data: Base.encode64(osr), length: replay_time(beatmap, replay.mods)},
        youtube: youtube_data(player, beatmap, replay),
        skin: skin(skin_override || player.username),
        status: status(:pending)
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @skins_api "https://circle-people.com/skins-api.php?player="
  @default_skin %{
    name: "CirclePeople Default 2017-08-16",
    url:
      "https://circle-people.com/wp-content/Skins/Default Skins/CirclePeople Default 2017-08-16.osk"
  }

  # Get a player's skin.
  @spec skin(binary) :: map
  defp skin(username) do
    case HTTPoison.get(@skins_api <> username) do
      {:ok, %{body: body}} ->
        if body === "" do
          notify("no skin available for user `#{username}`")
          if(username === "Default Skins", do: @default_skin, else: skin("Default Skins"))
        else
          name =
            body
            |> String.split("/")
            |> List.last()
            |> String.trim_trailing(".osk")

          %{name: name, url: body}
        end

      {:error, reason} ->
        notify(:warn, "couldn't get skin for user `#{username}`", reason)
        if(username === "Default Skins", do: @default_skin, else: skin("Default Skins"))
    end
  end

  @dt 64
  @ht 256

  # Compute the actual runtime of a replay, given its mods.
  @spec replay_time(map, integer) :: number
  defp replay_time(%{total_length: len}, mods) do
    cond do
      (mods &&& @dt) === @dt -> len / 1.5
      (mods &&& @ht) === @ht -> len * 1.5
      true -> len
    end
  end

  # This list is sorted in presentation order.
  @mods [
    EZ: 1 <<< 1,
    HD: 1 <<< 3,
    HT: 1 <<< 8,
    DT: 1 <<< 6,
    NC: 1 <<< 6 ||| 1 <<< 9,
    HR: 1 <<< 4,
    FL: 1 <<< 10,
    NF: 1 <<< 0,
    SD: 1 <<< 5,
    PF: 1 <<< 5 ||| 1 <<< 14,
    RX: 1 <<< 7,
    AP: 1 <<< 13,
    SO: 1 <<< 12,
    AT: 1 <<< 11,
    V2: 1 <<< 29,
    TD: 1 <<< 2
  ]

  @doc "Convert numeric mods to a string, e.g. 24 -> +HDHR."
  @spec mod_string(integer) :: binary | nil
  def mod_string(mods) do
    mods =
      @mods
      |> Enum.filter(fn {_m, v} -> (mods &&& v) === v end)
      |> Keyword.keys()

    mods = if(:NC in mods, do: List.delete(mods, :DT), else: mods)
    mods = if(:PF in mods, do: List.delete(mods, :SD), else: mods)

    if(Enum.empty?(mods), do: nil, else: "+" <> Enum.join(mods, ","))
  end

  @doc "Convert a replay into its accuracy, in percent."
  @spec accuracy(map) :: float | nil
  def accuracy(%{mode: 0} = replay) do
    100.0 * (300 * replay.n300 + 100 * replay.n100 + 50 * replay.n50) /
      (300 * replay.n300 + 300 * replay.n100 + 300 * replay.n50 + 300 * replay.nmiss)
  end

  defp accuracy(_replay) do
    nil
  end

  # Gets pp for a play.
  @spec pp_string(map, map, map) :: binary | nil
  defp pp_string(player, beatmap, replay) do
    case OsuEx.API.get_scores(beatmap.beatmap_id,
           u: player.user_id,
           m: replay.mode,
           mods: replay.mods
         ) do
      {:ok, [%{pp: pp}]} when is_number(pp) ->
        :erlang.float_to_binary(pp + 0.0, decimals: 0) <> "pp"

      {:ok, _scores} ->
        nil

      {:error, reason} ->
        notify(:warn, "looking up score failed", reason)
        nil
    end
  end

  # Generate the YouTube description.
  @spec description(map, map) :: binary
  defp description(%{username: username, user_id: user_id}, %{beatmap_id: beatmap_id}) do
    """
    #{username}'s Profile: https://osu.ppy.sh/u/#{user_id} | #{username}'s Skin: https://circle-people.com/skins | Map: https://osu.ppy.sh/b/#{
      beatmap_id
    } | Click "Show more" for an explanation what this video and free to play rhythm game is all about!

    ------------------------------------------------------

    osu! is the perfect game if you're looking for ftp games as osu! is a free to play online rhythm game, which you can use as a rhythm trainer online with lots of gameplay music!
    https://osu.ppy.sh
    osu! has online rankings, multiplayer and boasts a community with over 500,000 active users!

    Title explanation:
    GameMode | PlayerName | Artist - Song [Difficulty] +ModificationOfMap | PlayerAccuracyOnMap% PointsAwardedForThisPlayPP

    Want to support what we do? Check out our Patreon!
    https://www.patreon.com/circlepeople

    Join the CirclePeople community! https://discord.gg/CirclePeople
    Don't want to miss any pro plays? Subscribe or follow us!
    Twitter: https://twitter.com/CirclePeopleYT
    Facebook: https://facebook.com/CirclePeople

    Want some sweet custom covers for your tablet?
    https://yangu.pw/shop - Order here!

    #CirclePeople
    #osu
    ##{username}
    """
  end

  @doc "Defines the game mode enum."
  @spec mode(integer) :: binary
  def mode(0), do: "osu!"
  def mode(1), do: "osu!taiko"
  def mode(2), do: "osu!catch"
  def mode(3), do: "osu!mania"

  @title_limit 100

  # Get YouTube upload data for a play.
  @spec youtube_data(map, map, map) :: map
  defp youtube_data(player, beatmap, replay) do
    mods = mod_string(replay.mods)
    fc = if(replay.perfect?, do: "FC", else: nil)
    percent = accuracy(replay)
    pp = pp_string(player, beatmap, replay)

    acc_s =
      if is_nil(percent) do
        nil
      else
        :erlang.float_to_binary(percent, decimals: 2) <> "%"
      end

    extra =
      [mods, acc_s, fc, pp]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    title =
      "#{mode(replay.mode)} | #{player.username} | #{beatmap.artist} - #{beatmap.title} [#{
        beatmap.version
      }] #{extra}"

    yt_title = if(String.length(title) > @title_limit, do: "Placeholder Title", else: title)

    desc = title <> "\n" <> description(player, beatmap)
    %{title: yt_title, description: desc}
  end

  @spec extract_username(binary) :: {:ok, binary} | {:error, :no_player_match}
  defp extract_username(title) do
    case Regex.run(~r/(.+?)\|/, title, capture: :all_but_first) do
      [cap] ->
        {:ok,
         cap
         |> (&Regex.replace(~r/\(.*?\)/, &1, "")).()
         |> String.trim()}

      nil ->
        {:error, :no_player_match}
    end
  end

  @spec extract_map_name(binary) :: {:ok, binary} | {:error, :no_map_match}
  defp extract_map_name(title) do
    case Regex.run(~r/\|(.+?)-(.+?)\[(.+?)\]/, title, capture: :all_but_first) do
      [artist, title, diff] ->
        {:ok, "#{String.trim(artist)} - #{String.trim(title)} [#{String.trim(diff)}]"}

      nil ->
        {:error, :no_map_match}
    end
  end

  @spec search_beatmap(map, binary) :: {:ok, map} | {:error, term}
  defp search_beatmap(player, map_name) do
    notify(:debug, "searching for: #{map_name}")
    map_name = String.downcase(map_name)

    try do
      case search_events(player, map_name) do
        {:ok, beatmap} -> throw(beatmap)
        _ -> nil
      end

      case search_recent(player, map_name) do
        {:ok, beatmap} -> throw(beatmap)
        _ -> nil
      end

      case search_best(player, map_name) do
        {:ok, beatmap} -> throw(beatmap)
        _ -> nil
      end

      nil
    catch
      beatmap -> {:ok, beatmap}
    end
  end

  # Search a player's recent events for a beatmap.
  @spec search_events(map, binary) :: {:ok, map} | {:error, term}
  defp search_events(%{events: events}, map_name) do
    case Enum.find(events, fn %{display_html: html} ->
           html
           |> String.downcase()
           |> String.contains?(map_name)
         end) do
      %{beatmap_id: id} -> OsuEx.API.get_beatmap(id)
      _ -> {:error, nil}
    end
  end

  # Search a player's recent plays for a beatmap.
  @spec search_recent(map, binary) :: {:ok, map} | {:error, term}
  defp search_recent(%{user_id: id}, map_name) do
    case OsuEx.API.get_user_recent(id) do
      {:ok, scores} -> search_scores(scores, map_name)
      {:error, reason} -> {:error, reason}
    end
  end

  # Search a player's best plays for a beatmap.
  @spec search_best(map, binary) :: {:ok, map} | {:error, term}
  defp search_best(%{user_id: id}, map_name) do
    case OsuEx.API.get_user_best(id) do
      {:ok, scores} -> search_scores(scores, map_name)
      {:error, reason} -> {:error, reason}
    end
  end

  # Search a list of scores for a beatmap.
  @spec search_scores(map, binary) :: {:ok, map} | {:error, term}
  defp search_scores(scores, map_name) do
    Enum.find_value(scores, {:error, :not_found}, fn %{beatmap_id: map_id} ->
      case OsuEx.API.get_beatmap(map_id) do
        {:ok, %{artist: artist, title: title, version: version} = beatmap} ->
          if String.downcase("#{artist} - #{title} [#{version}]") === map_name do
            beatmap
          else
            false
          end

        _ ->
          false
      end
    end)
  end

  @downloader Application.get_env(:oaas, :osr_downloader)

  # Download a .osr replay file.
  @spec get_osr(map, map) :: {:ok, binary} | {:error, {:exit_code, integer}}
  defp get_osr(%{user_id: user}, %{beatmap_id: beatmap}) do
    args =
      [@downloader, "-k", Application.get_env(:osu_ex, :api_key), "-u", user, "-b", beatmap]
      |> Enum.map(&to_string/1)

    case System.cmd(@downloader, args) do
      {osr, 0} -> {:ok, osr}
      {_, n} -> {:error, {:exit_code, n}}
    end
  end
end
