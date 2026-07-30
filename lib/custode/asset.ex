defmodule Custode.Asset do
  @moduledoc """
  One resolved packaged asset: its identity, its exact content, and where
  that content came from (#269).

  `version` is derived from the content rather than declared beside it. A
  version an author has to remember to bump is a version that silently stops
  describing the bytes, and the whole point of recording an asset on an
  Attempt is being able to say what text actually ran.
  """

  @enforce_keys [:id, :version, :digest, :media_type, :origin, :path, :content]
  defstruct @enforce_keys

  @type origin :: :packaged | :config_dir | :config

  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          digest: String.t(),
          media_type: String.t(),
          origin: origin(),
          path: String.t(),
          content: String.t()
        }

  @doc "The reference shape recorded on RoleTemplates, ContextBundles and Attempts."
  @spec reference(t()) :: map()
  def reference(%__MODULE__{} = asset) do
    %{
      "kind" => "packaged_asset",
      "id" => asset.id,
      "version" => asset.version,
      "digest" => asset.digest,
      "origin" => Atom.to_string(asset.origin)
    }
  end
end
