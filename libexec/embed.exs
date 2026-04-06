#!/usr/bin/env elixir

#-------------------------------------------------------------------------------
# Embedding generator
#
# Reads text from a file (or stdin when "-" is given) and outputs its embedding
# vector as a JSON array of floats to stdout. Uses Bumblebee with the
# all-MiniLM-L12-v2 sentence transformer model, which produces 384-dimensional
# vectors suitable for semantic similarity.
#
# The model is downloaded from HuggingFace on first run and cached locally
# under ~/.config/scratch/models/.
#
# Usage:
#   helpers/embed <file>       # embed the contents of a file
#   echo "some text" | helpers/embed -   # embed from stdin
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

  def run(text) do
    model_name = model()

    {:ok, model} = Bumblebee.load_model({:hf, model_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(
        model,
        tokenizer,
        compile: [batch_size: 1, sequence_length: 128],
        defn_options: [compiler: EXLA],
        output_pool: :mean_pooling,
        output_attribute: :hidden_state
      )

    %{embedding: tensor} = Nx.Serving.run(serving, text)

    tensor
    |> Nx.to_flat_list()
    |> Jason.encode!()
  end
end

# Read input from file arg or stdin
text =
  case System.argv() do
    ["-"] ->
      IO.read(:stdio, :eof)

    [path] ->
      case File.read(path) do
        {:ok, content} -> content
        {:error, reason} ->
          IO.puts(:standard_error, "error: #{path}: #{:file.format_error(reason)}")
          System.halt(1)
      end

    [] ->
      IO.puts(:standard_error, "Usage: embed <file>  or  embed -")
      System.halt(1)

    _ ->
      IO.puts(:standard_error, "Usage: embed <file>  or  embed -")
      System.halt(1)
  end

text = String.trim(text)

if text == "" do
  IO.puts(:standard_error, "error: empty input")
  System.halt(1)
end

IO.puts(Embed.run(text))
