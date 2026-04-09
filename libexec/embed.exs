#!/usr/bin/env elixir

#-------------------------------------------------------------------------------
# Embedding generator
#
# Generates embedding vectors using Bumblebee with the all-MiniLM-L12-v2
# sentence transformer (384-dimensional vectors, mean pooling).
#
# Two modes, dispatched by System.argv():
#
#   Single-input mode (backward compatible):
#     helpers/embed <file>       # embed file contents, output JSON array
#     echo "text" | helpers/embed -   # embed stdin text, output JSON array
#
#   Pool mode (JSONL streaming):
#     ... | helpers/embed -n 4   # read JSONL from stdin, output JSONL
#
#     Pool mode loads the model once, then processes a stream of inputs
#     via Task.async_stream with bounded concurrency. Each input line is
#     a JSON object with "id" and "text" fields. Each output line is a
#     JSON object with "id" and "embedding" fields. Results arrive in
#     completion order. Pipe backpressure keeps memory bounded.
#
# Environment:
#   SCRATCH_MODEL   Override the default embedding model
#
# Dependencies: elixir (with Mix.install support)
#
# Compilation notes:
#
#   EXLA pins: EXLA 0.10.0 has a duplicate symbol linker error in the `fine`
#   library's init functions (init_atoms, init_resources) across multiple
#   translation units (exla.o, exla_client.o, exla_mlir.o). Pinned to 0.9.2
#   to avoid it.
#
#   Clang workaround: Apple clang 17+ (Xcode 16+) promotes
#   -Wmissing-template-arg-list-after-template-kw to a hard error, which
#   breaks compilation of XLA's async_value_ref.h headers. EXLA's Makefile
#   already passes -w (suppress warnings), but clang treats this as an error,
#   not a warning. The fix is setting CXX with
#   -Wno-error=missing-template-arg-list-after-template-kw before Mix.install
#   compiles the NIF. Since an Elixir script can't set env before its own
#   process starts, helpers/embed wraps this script and exports CXX.
#
#   This only matters on the first run (NIF compilation). Subsequent runs use
#   the cached .so from Mix's install cache.
#-------------------------------------------------------------------------------

# Route Elixir/EXLA log noise to stderr so stdout stays clean for JSON output
{:ok, cfg} = :logger.get_handler_config(:default)
cfg = Map.update!(cfg, :config, &Map.put(&1, :type, :standard_error))
:ok = :logger.remove_handler(:default)
:ok = :logger.add_handler(:default, :logger_std_h, cfg)
:ok = :logger.set_primary_config(:level, :warning)

# Cache models under ~/.config/scratch/models/ instead of the default
# HuggingFace cache location. Bumblebee reads BUMBLEBEE_CACHE_DIR.
cache_dir = Path.join([System.user_home!(), ".config", "scratch", "models"])
File.mkdir_p!(cache_dir)
System.put_env("BUMBLEBEE_CACHE_DIR", cache_dir)

Mix.install([
  {:bumblebee, "~> 0.6"},
  {:exla, "0.9.2"},
  {:jason, "~> 1.4"},
])

Nx.global_default_backend(EXLA.Backend)

defmodule Embed do
  @default_model "sentence-transformers/all-MiniLM-L12-v2"

  def model, do: System.get_env("SCRATCH_MODEL") || @default_model

  def load_serving do
    model_name = model()

    {:ok, model} = Bumblebee.load_model({:hf, model_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

    Bumblebee.Text.TextEmbedding.text_embedding(
      model,
      tokenizer,
      compile: [batch_size: 1, sequence_length: 128],
      defn_options: [compiler: EXLA],
      output_pool: :mean_pooling,
      output_attribute: :hidden_state
    )
  end

  def embed(serving, text) do
    %{embedding: tensor} = Nx.Serving.run(serving, text)
    Nx.to_flat_list(tensor)
  end
end

# Parse arguments to determine mode
{opts, args} =
  case System.argv() do
    ["-n", n | rest] ->
      {[pool: String.to_integer(n)], rest}

    ["-n"] ->
      {[pool: 4], []}

    other ->
      {[], other}
  end

# Load model (shared across both modes)
serving = Embed.load_serving()

case {opts[:pool], args} do
  # Pool mode: read JSONL from stdin, output JSONL
  {concurrency, []} when is_integer(concurrency) ->
    IO.stream(:stdio, :line)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Task.async_stream(
      fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => id, "text" => text}} when is_binary(text) and text != "" ->
            embedding = Embed.embed(serving, text)
            Jason.encode!(%{id: id, embedding: embedding})

          {:ok, %{"id" => id}} ->
            Jason.encode!(%{id: id, error: "missing or empty text field"})

          {:error, _} ->
            Jason.encode!(%{error: "invalid JSON: #{String.slice(line, 0, 80)}"})
        end
      end,
      max_concurrency: concurrency,
      ordered: false
    )
    |> Stream.each(fn {:ok, json_line} ->
      IO.puts(json_line)
    end)
    |> Stream.run()

  # Single-input mode: embed one text, output bare JSON array
  {nil, ["-"]} ->
    text = IO.read(:stdio, :eof) |> String.trim()

    if text == "" do
      IO.puts(:standard_error, "error: empty input")
      System.halt(1)
    end

    Embed.embed(serving, text) |> Jason.encode!() |> IO.puts()

  {nil, [path]} ->
    case File.read(path) do
      {:ok, content} ->
        text = String.trim(content)

        if text == "" do
          IO.puts(:standard_error, "error: empty input")
          System.halt(1)
        end

        Embed.embed(serving, text) |> Jason.encode!() |> IO.puts()

      {:error, reason} ->
        IO.puts(:standard_error, "error: #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end

  {nil, []} ->
    IO.puts(:standard_error, "Usage: embed <file>  |  embed -  |  ... | embed -n <workers>")
    System.halt(1)

  _ ->
    IO.puts(:standard_error, "Usage: embed <file>  |  embed -  |  ... | embed -n <workers>")
    System.halt(1)
end
