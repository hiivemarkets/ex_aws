defmodule ExAws.Request.Req do
  @behaviour ExAws.Request.HttpClient

  @moduledoc """
  Configuration for `m:Req`.

  Options can be set for `m:Req` with the following config:

      config :ex_aws, :req_opts,
        receive_timeout: 30_000

  The default config handles setting the above.
  """
  alias Req.Response
  alias Req.Response.Async

  @default_opts [receive_timeout: 30_000]

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ [], stream? \\ false) do
    http_opts = rename_follow_redirect(http_opts)

    [method: method, url: url, body: body, headers: headers, decode_body: false, retry: false]
    |> maybe_stream_body(stream?)
    |> Keyword.merge(Application.get_env(:ex_aws, :req_opts, @default_opts))
    |> Keyword.merge(http_opts)
    |> Req.request()
    |> case do
      {:ok, %Response{body: %Async{}, status: status} = resp} ->
        stream =
          Stream.resource(
            fn -> resp end,
            &continue_stream/1,
            &finish_stream/1
          )

        {:ok, %{status_code: status, headers: Req.get_headers_list(resp), stream: stream}}
      {:ok, %{status: status, body: body} = resp} ->
        {:ok, %{status_code: status, headers: Req.get_headers_list(resp), body: body}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  # Req >= 0.4.0 uses :redirect, but some clients pass the :hackney option
  # :follow_redirect. Rename the option for Req to use.
  defp rename_follow_redirect(opts) do
    {follow, opts} = Keyword.pop(opts, :follow_redirect, false)

    Keyword.put(opts, :redirect, follow)
  end

  # PRIVATE FUNCTIONS
  ###################
  defp maybe_stream_body(opts, true), do: [{:into, :self} | opts]

  defp maybe_stream_body(opts, _), do: opts

  defp continue_stream({:cont, acc}, response), do: {Enum.reverse(acc), response}

  defp continue_stream({:halt, acc}, _response), do: {:halt, Enum.reverse(acc)}

  defp continue_stream(response) do
    case Req.parse_message(response, receive do message -> message end) do
      {:ok, chunks} ->
        chunks
        |> Enum.reduce({:cont, []}, fn
             {:data, binary}, {instruction, acc} ->
               {instruction, [binary | acc]}

             {:trailers, _trailers}, acc ->
               acc

             :done, {_instruction, acc} ->
               {:halt, acc}
        end)
        |> continue_stream(response)

      {:error, reason} ->
        raise reason
    end
  end

  defp finish_stream(response), do: response
end
