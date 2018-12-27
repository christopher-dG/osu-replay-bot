defmodule OAAS.Discord do
  @moduledoc "The Discord bot."

  alias Nostrum.Api
  use Nostrum.Consumer
  import OAAS.Utils
  alias OAAS.Job
  alias OAAS.Reddit
  alias OAAS.Worker

  @me Application.get_env(:oaas, :discord_user)
  @channel Application.get_env(:oaas, :discord_channel)
  @plusone "👍"

  def start_link do
    Consumer.start_link(__MODULE__)
  end

  # Add a job via a replay attachment.
  def handle_event(
        {:MESSAGE_CREATE,
         {%{
            attachments: [%{url: url}],
            channel_id: @channel,
            content: content,
            mentions: [%{id: @me}]
          }}, _state}
      ) do
    skin =
      case Regex.run(~r/skin:(.+)/i, content, capture: :all_but_first) do
        [skin] -> String.trim(skin)
        nil -> nil
      end

    case Job.from_osr(url, skin) do
      {:ok, j} -> notify("created job `#{j.id}`")
      {:error, reason} -> notify(:error, "creating job failed", reason)
    end
  end

  # Command entrypoint.
  def handle_event(
        {:MESSAGE_CREATE,
         {%{
            content: content,
            channel_id: @channel,
            mentions: [%{id: @me}]
          } = msg}, _state}
      ) do
    content
    |> String.split()
    |> tl()
    |> command(msg)
  end

  def handle_event(
        {:MESSAGE_REACTION_ADD,
         {%{
            channel_id: @channel,
            emoji: %{name: @plusone},
            message_id: message
          }}, _state}
      ) do
    case Api.get_channel_message(@channel, message) do
      {:ok, %{author: %{id: @me}, content: "reddit post:" <> content}} ->
        with [p_id] <- Regex.run(~r/https:\/\/redd.it\/(.+)/i, content, capture: :all_but_first),
             [title] <- Regex.run(~r/title: (.+)/i, content, capture: :all_but_first) do
          case Job.from_reddit(p_id, title) do
            {:ok, %{replay: replay, id: j_id}} ->
              notify("created job `#{j_id}`")

              """
              job `#{j_id}`'s downloaded replay has the following properties:
              ```yml
              player: #{replay.player}
              mode:  #{Job.mode(replay.mode)}
              mods:  #{Job.mod_string(replay.mods)}
              combo: #{replay.combo}
              score: #{replay.score}
              accuracy: #{Job.accuracy(replay)}
              ```
              please ensure that this is accurate, otherwise run `delete job #{j_id}` immediately
              """
              |> send_message()

              Reddit.save_post(p_id)

            {:error, reason} ->
              notify(:error, "creating job failed", reason)
          end
        else
          nil -> notify(:warn, "parsing message failed")
        end

      {:ok, msg} ->
        notify(:debug, "message #{msg.id} is not a reddit notification")

      {:error, reason} ->
        notify(:warn, "getting message #{message} failed", reason)
    end
  end

  # Fallback event handler.
  def handle_event(_e) do
    :noop
  end

  def send_message(content) do
    Api.create_message(@channel, content)
  end

  # List workers.
  defp command(["list", "workers"], _msg) do
    case Worker.get() do
      {:ok, ws} ->
        ws
        |> Enum.map(&Map.put(&1, :online, Worker.online?(&1)))
        |> table([:online, :current_job_id], [:online, :job])
        |> send_message()

      {:error, reason} ->
        notify(:error, "listing workers failed", reason)
    end
  end

  # List jobs.
  defp command(["list", "jobs"], _msg) do
    case Job.get() do
      {:ok, js} ->
        js
        |> Enum.reject(&Job.finished/1)
        |> Enum.map(fn j -> Map.update!(j, :status, &Job.status/1) end)
        |> table([:worker_id, :status, :comment], [:worker, :status, :comment])
        |> send_message()

      {:error, reason} ->
        notify(:error, "listing jobs failed", reason)
    end
  end

  # Describe a worker.
  defp command(["describe", "worker", id], _msg) do
    case Worker.get(id) do
      {:ok, w} ->
        """
        ```
        id: #{w.id}
        online: #{Worker.online?(w)}
        job: #{w.current_job_id || "none"}
        last poll: #{relative_time(w.last_poll)}
        last job: #{relative_time(w.last_job)}
        created: #{relative_time(w.created_at)}
        updated: #{relative_time(w.updated_at)}
        ```
        """
        |> send_message()

      {:error, reason} ->
        notify(:error, "looking up worker failed", reason)
    end
  end

  # Describe a job.
  defp command(["describe", "job", id], _msg) do
    with {id, ""} <- Integer.parse(id),
         {:ok, %Job{} = j} <- Job.get(id) do
      player = "#{j.player.username} (https://osu.ppy.sh/u/#{j.player.user_id})"

      beatmap =
        "#{j.beatmap.artist} - #{j.beatmap.title} [#{j.beatmap.version}] (https://osu.ppy.sh/b/#{
          j.beatmap.beatmap_id
        })"

      """
      ```
      id: #{j.id}
      worker: #{j.worker_id || "none"}
      status: #{Job.status(j.status)}
      comment: #{j.comment || "none"}
      player: #{player}
      beatmap: #{beatmap}
      video: #{j.youtube.title}
      skin: #{(j.skin || %{})[:name] || "none"}
      created: #{relative_time(j.created_at)}
      updated: #{relative_time(j.updated_at)}
      ```
      """
      |> send_message()
    else
      :error -> notify(:error, "invalid job id")
      {:ok, nil} -> notify(:error, "no such job")
      {:error, reason} -> notify(:error, "looking up job failed", reason)
    end
  end

  # Delete a job.
  defp command(["delete", "job", id], _msg) do
    with {id, ""} <- Integer.parse(id),
         {:ok, j} <- Job.get(id),
         {:ok, j} <- Job.mark_deleted(j) do
      notify("deleted job `#{j.id}`")
    else
      :error -> notify(:error, "invalid job id")
      {:error, reason} -> notify(:error, "deleting job failed", reason)
    end
  end

  # Fallback command.
  defp command(cmd, _msg) do
    """
    ```
    unrecognized command: #{Enum.join(cmd, " ")}
    usage: <mention> <cmd>
    commands:
    * list (jobs | workers)
    * describe (job | worker) <id>
    * delete job <id>
    or, attach a .osr file to create a new job
    ```
    """
    |> send_message()
  end

  # Generate an ascii table from a list of models.
  @spec table([struct], [atom], [atom]) :: binary
  defp table([], _rows, _headers) do
    "no entries"
  end

  defp table(structs, rows, headers) do
    t =
      structs
      |> Enum.map(fn x ->
        [x.id] ++
          Enum.map(rows, &Map.get(x, &1)) ++
          [relative_time(x.created_at), relative_time(x.updated_at)]
      end)
      |> TableRex.quick_render!([:id] ++ headers ++ [:created, :updated])

    "```\n#{t}\n```"
  end

  @spec relative_time(nil) :: binary
  defp relative_time(nil) do
    "never"
  end

  @spec relative_time(non_neg_integer) :: binary
  defp relative_time(ms) do
    dt = Timex.from_unix(ms, :millisecond)

    case Timex.Format.DateTime.Formatters.Relative.format(dt, "{relative}") do
      {:ok, rel} -> rel
      {:error, _reason} -> to_string(dt)
    end
  end
end
