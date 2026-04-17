defmodule Equinox.Session.Storage do
  @moduledoc """
  管理特定会话（Session/Project）的隔离缓存和数据存储配置。
  """

  @type storage :: term()
  @type store_conf :: {module(), storage()} | nil

  @type t :: %__MODULE__{
          meta_conf: store_conf(),
          blob_conf: store_conf(),
          interv_conf: store_conf(),
          merge_conf: store_conf()
        }

  defstruct [:meta_conf, :blob_conf, :interv_conf, :merge_conf]

  alias OrchidStratum.MetaStorage.EtsAdapter, as: EtsMetaStorage
  alias OrchidStratum.BlobStorage.EtsAdapter, as: EtsBlobStorage

  @spec new() :: t()
  def new do
    meta_ref = EtsMetaStorage.init()
    blob_ref = EtsBlobStorage.init()
    new({EtsMetaStorage, meta_ref}, {EtsBlobStorage, blob_ref}, nil, nil)
  end

  @spec new(store_conf(), store_conf(), store_conf(), store_conf()) :: t()
  def new(meta_conf, blob_conf, interv_conf, merge_conf) do
    %__MODULE__{
      meta_conf: meta_conf,
      blob_conf: blob_conf,
      interv_conf: interv_conf,
      merge_conf: merge_conf
    }
  end
end
