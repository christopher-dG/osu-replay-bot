defmodule OAAS.Discord do
  @moduledoc "Interacts with Discord for application control."

  alias Nostrum.Api
  alias OAAS.Job
  alias OAAS.Job.Replay
  alias OAAS.Queue
  alias OAAS.Worker
  import OAAS.Utils
  use Nostrum.Consumer

  @plusone "👍"
  @shutdown_message "React #{@plusone} to shut down."

  def start_link do
    Consumer.start_link(__MODULE__)
  end

  @spec me :: integer
  defp me, do: Application.fetch_env!(:oaas, :discord_user)

  @spec channel :: integer
  defp channel, do: Application.fetch_env!(:oaas, :discord_channel)

  @spec admin :: integer
  defp admin, do: Application.fetch_env!(:oaas, :discord_admin)

  def handle_event({:MESSAGE_CREATE, %{} = message, _state}) do
    me = me()
    channel = channel()

    case message do
      # Replay job via replay attachment.
      %{
        attachments: [%{url: url}],
        channel_id: ^channel,
        content: content,
        mentions: [%{id: ^me}]
      } ->
        notify(:debug, "Received attachment: #{url}.")

        skin =
          case Regex.run(~r/skin:(.+)/i, content) do
            [_, skin] ->
              s = String.trim(skin)
              notify(:debug, "Skin override: #{s}.")
              s

            nil ->
              nil
          end

        case Replay.from_osr(url, skin) do
          {:ok, j} ->
            notify("Created job `#{j.id}`.\n#{Replay.describe(j)}")
            send(Queue, :work)

          {:error, reason} ->
            notify(:error, "Creating job failed.", reason)
        end

      # Command entrypoint.
      %{
        content: content,
        channel_id: ^channel,
        mentions: [%{id: ^me}]
      } ->
        notify(:debug, "Received message mention: #{content}.")

        content
        |> String.split()
        |> tl()
        |> command(message)

      _message ->
        :noop
    end
  end

  def handle_event({:MESSAGE_REACTION_ADD, %{} = reaction, _state}) do
    channel = channel()

    case reaction do
      # Confirm a shutdown or add a replay job via a reaction on a Reddit post notification.
      %{
        channel_id: ^channel,
        emoji: %{name: @plusone},
        message_id: message
      } ->
        notify(:debug, "Received :+1: reaction on message #{message}.")
        me = me()

        case Api.get_channel_message(channel(), message) do
          {:ok, %{author: %{id: ^me}, content: content}} ->
            notify(:debug, "Message contents: '#{content}'.")

            case content do
              @shutdown_message ->
                notify("Shutting down.")
                :init.stop()

              "New score post" <> _s = content ->
                with [_, p_id] <- Regex.run(~r|redd\.it/(.+)|, content),
                     [_, title] <- Regex.run(~r|Post: `(.+?)`|, content) do
                  case Replay.from_reddit(p_id, title) do
                    {:ok, j} ->
                      notify("Created job `#{j.id}`.\n#{Replay.describe(j)}")
                      send(Queue, :work)

                    {:error, reason} ->
                      notify(:error, "Creating job failed.", reason)
                  end
                else
                  nil -> notify(:warn, "Reddit post ID or title could not be parsed.")
                end

              _ ->
                notify(:debug, "Not a shutdown command or reddit notification.")
            end

          {:ok, _msg} ->
            :noop

          {:error, reason} ->
            notify(:warn, "Getting message #{message} failed.", reason)
        end

      _reaction ->
        :noop
    end
  end

  # Fallback event handler.
  def handle_event(_e) do
    :noop
  end

  @doc "Sends a Discord message."
  @spec send_message(String.t()) :: {:ok, Nostrum.Struct.Message.t()} | {:error, term}
  def send_message(content) do
    unless env() === :test do
      case Api.create_message(channel(), content) do
        {:ok, msg} ->
          {:ok, msg}

        {:error, reason} ->
          notify(:debug, "Sending message failed.", reason)
          {:error, reason}
      end
    end
  end

  # List workers.
  defp command(["list", "workers"], _msg) do
    notify(:debug, "Listing workers.")

    case Worker.get() do
      {:ok, ws} ->
        ws
        |> Enum.map(&Map.put(&1, :online, Worker.online?(&1)))
        |> table([:online, :current_job_id], [:online, :job])
        |> send_message()

      {:error, reason} ->
        notify(:error, "Listing workers failed.", reason)
    end
  end

  # List jobs.
  defp command(["list", "jobs"], _msg) do
    notify(:debug, "Listing jobs.")

    case Job.get() do
      {:ok, js} ->
        js
        |> Enum.reject(&Job.finished/1)
        |> Enum.map(fn j -> Map.update!(j, :status, &Job.status/1) end)
        |> table([:worker_id, :status, :comment], [:worker, :status, :comment])
        |> send_message()

      {:error, reason} ->
        notify(:error, "Listing jobs failed.", reason)
    end
  end

  # Describe a worker.
  defp command(["describe", "worker", id], _msg) do
    notify(:debug, "Describing worker #{id}.")

    case Worker.get(id) do
      {:ok, w} ->
        w
        |> Worker.describe()
        |> send_message()

      {:error, reason} ->
        notify(:error, "Looking up worker failed.", reason)
    end
  end

  # Describe a job.
  defp command(["describe", "job", id], _msg) do
    notify(:debug, "Describing job #{id}.")

    with {id, ""} <- Integer.parse(id),
         {:ok, j} <- Job.get(id) do
      j
      |> Job.type(j.type).describe()
      |> send_message()
    else
      :error -> notify(:error, "Invalid job ID `#{id}`.")
      {:error, reason} -> notify(:error, "Looking up job failed.", reason)
    end
  end

  # Delete a job.
  defp command(["delete", "job", id], _msg) do
    notify(:debug, "Deleting job #{id}.")

    with {id, ""} <- Integer.parse(id),
         {:ok, j} <- Job.get(id),
         {:ok, j} <- Job.mark_deleted(j) do
      notify("Deleted job `#{j.id}`.")
    else
      :error -> notify(:error, "Invalid job ID `#{id}`.")
      {:error, reason} -> notify(:error, "Deleting job failed.", reason)
    end
  end

  # Process the queue.
  defp command(["process", "queue"], %{id: id}) do
    notify(:debug, "Processing queue via request #{id}.")
    send(Queue, :work)
    Api.create_reaction(channel(), id, @plusone)
  end

  # Start the shutdown sequence.
  defp command(["shutdown"], _msg) do
    notify(:debug, "Starting shutdown sequence.")
    send_message(@shutdown_message)
  end

  # Evaluate some code.
  defp command(["eval" | _t], %{author: %{id: id}, content: content}) do
    if id == admin() do
      case Regex.run(~r/```.*?\n(.*)\n```/s, content) do
        nil ->
          notify(:warn, "Invalid eval input.")

        [_, code] ->
          try do
            Code.eval_string(code)
          rescue
            reason -> notify(:warn, "Eval failed (exception).", reason)
          catch
            reason -> notify(:warn, "Eval failed (throw).", reason)
          else
            {result, _} -> send_message("```elixir\n#{inspect(result)}\n```")
          end
      end
    end
  end

  # Fallback command.
  defp command(cmd, _msg) do
    notify(:debug, "Unrecognized command #{Enum.join(cmd, " ")}.")

    """
    ```
    Unrecognized command: #{Enum.join(cmd, " ")}.
    Usage: <mention> <cmd>
    Commands:
    * list (jobs | workers)
    * describe (job | worker) <id>
    * delete job <id>
    * process queue
    * shutdown
    * eval (admin only)
    Or, attach a replay (.osr) file to create a new job.
    ```
    """
    |> send_message()
  end

  # Generate an ascii table from a list of models.
  @spec table([], [atom], [atom]) :: String.t()
  defp table([], _rows, _headers) do
    "No entries."
  end

  @spec table([struct], [atom], [atom]) :: String.t()
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
end
