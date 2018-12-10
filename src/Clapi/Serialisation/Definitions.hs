{-# OPTIONS_GHC -Wno-orphans #-}

module Clapi.Serialisation.Definitions where

import Clapi.Serialisation.Base
  (Encodable(..), Decodable(..), (<<>>), tdTaggedBuilder, tdTaggedParser)
import Clapi.Serialisation.Path ()
import Clapi.TaggedData (TaggedData, taggedData)
import Clapi.TextSerialisation (ttToText, ttFromText)
import Clapi.TH (btq)
import Clapi.Types.Definitions
  ( Editable(..), MetaType(..), metaType
  , TupleDefinition(..), StructDefinition(..), ArrayDefinition(..)
  , Definition(..), defDispatch, PostDefinition(..))
import Clapi.Types.Tree (TreeType)

editableTaggedData :: TaggedData Editable Editable
editableTaggedData = taggedData toTag id
  where
    toTag r = case r of
      Editable -> [btq|w|]
      ReadOnly -> [btq|r|]

instance Encodable Editable where
  builder = tdTaggedBuilder editableTaggedData $ const $ return mempty
instance Decodable Editable where
  parser = tdTaggedParser editableTaggedData return

-- FIXME: do we want to serialise the type to text first?!
instance Encodable TreeType where
  builder = builder . ttToText
instance Decodable TreeType where
  parser = parser >>= ttFromText

instance Encodable TupleDefinition where
  builder (TupleDefinition doc types interpl) =
    builder doc <<>> builder types <<>> builder interpl
instance Decodable TupleDefinition where
  parser = TupleDefinition <$> parser <*> parser <*> parser

instance Encodable StructDefinition where
  builder (StructDefinition doc tyinfo) = builder doc <<>> builder tyinfo
instance Decodable StructDefinition where
  parser = StructDefinition <$> parser <*> parser

instance Encodable ArrayDefinition where
  builder (ArrayDefinition doc ptn ctn cl) =
    builder doc <<>> builder ptn <<>> builder ctn <<>> builder cl
instance Decodable ArrayDefinition where
  parser = ArrayDefinition <$> parser <*> parser <*> parser <*> parser

defTaggedData :: TaggedData MetaType Definition
defTaggedData = taggedData typeToTag (defDispatch metaType)
  where
    typeToTag mt = case mt of
      Tuple -> [btq|T|]
      Struct -> [btq|S|]
      Array -> [btq|A|]

instance Encodable Definition where
  builder = tdTaggedBuilder defTaggedData $ \def -> case def of
    TupleDef d -> builder d
    StructDef d -> builder d
    ArrayDef d -> builder d
instance Decodable Definition where
  parser = tdTaggedParser defTaggedData $ \mt -> case mt of
    Tuple -> TupleDef <$> parser
    Struct -> StructDef <$> parser
    Array -> ArrayDef <$> parser

instance Encodable PostDefinition where
  builder (PostDefinition doc args) = builder doc <<>> builder args
instance Decodable PostDefinition where
  parser = PostDefinition <$> parser <*> parser
