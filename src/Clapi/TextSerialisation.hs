{-# LANGUAGE OverloadedStrings #-}
module Clapi.TextSerialisation where
import Data.Monoid
import Data.Text (Text, unpack, empty)
import Control.Applicative ((<|>))

import Blaze.ByteString.Builder (Builder)
import Blaze.ByteString.Builder.Char.Utf8 (fromString, fromChar, fromShow)

import Data.Attoparsec.Text (
    Parser, char, decimal, takeTill, many1, IResult(..), satisfy, inClass,
    parse, (<?>), endOfInput)

import qualified Clapi.Serialisation as Wire
import Clapi.TaggedData (tdAllTags, tdInstanceToTag, tdTagToEnum, TaggedData)
import Clapi.Types (
    Time(..), ClapiTypeEnum(..), ClapiValue(..), DataUpdateMessage(..), Interpolation(..), InterpolationType(..))
import Clapi.Path (Path)

cvBuilder :: ClapiValue -> Builder
cvBuilder (ClInt32 i) = fromShow i
cvBuilder (ClString s) = fromShow s
-- I think this is the best you can do without path specific type info:
cvBuilder (ClEnum i) = fromShow i

tdTaggedBuilder :: TaggedData e a -> (a -> Builder) -> a -> Builder
tdTaggedBuilder td bdr a = fromChar (tdInstanceToTag td $ a) <> bdr a

msgBuilder :: DataUpdateMessage -> Builder
msgBuilder = tdTaggedBuilder Wire.dumtTaggedData dumBuilder
  where
    dumBuilder msg = case msg of
        (UMsgSet {}) -> tab valSubs msg
        (UMsgAdd {}) -> tab valSubs msg
        (UMsgRemove {}) -> tab noSubs msg
    tb (Time s f) = (fromShow s) <> (fromChar ':') <> (fromShow f)
    ab ma = case ma of
        (Just  a) -> fromShow a
        Nothing -> fromString "\"\""
    tab subs msg = spJoin $
        [tb $ duMsgTime msg] ++ (subs msg) ++ [ab $ duMsgAttributee msg]
    spJoin bs = mconcat $ fmap (fromChar ' ' <>) bs
    vb vs = fmap cvBuilder vs
    ib = tdTaggedBuilder Wire.interpolationTaggedData $ \i -> case i of
        (IBezier a b) -> error "bezier text serialisation not implemented"
        _ -> mempty
    valSubs msg = (vb $ duMsgArgs msg) ++ [ib $ duMsgInterpolation msg]
    noSubs _ = []

headerBuilder :: DataUpdateMessage -> Builder
headerBuilder = fromString . fmap (tdInstanceToTag Wire.cvTaggedData) . duMsgArgs

-- Not sure how useful this is because how often do you know all the messages
-- up front?
encode :: [DataUpdateMessage] -> Builder
encode msgs = header <> bodyBuilder
  where
    -- It is invalid for a time series to be empty, so this use of head is
    -- kinda fine, but the errors will suck:
    header = headerBuilder $ head $ msgs
    bodyBuilder = mconcat $ fmap (\tp -> fromChar '\n' <> msgBuilder tp) msgs

quotedString :: Parser Text
-- FIXME: escaped quotes unsupported
quotedString = do
    char '"'
    s <- takeTill (== '"')
    char '"'
    return s

cvParser :: ClapiTypeEnum -> Parser ClapiValue
cvParser ClTInt32 = (ClInt32 <$> decimal) <?> "ClInt32"
cvParser ClTString = (ClString <$> quotedString) <?> "ClString"
cvParser ClTEnum = (ClEnum <$> decimal) <?> "ClEnum"

charIn :: String -> String -> Parser Char
charIn cls msg = satisfy (inClass cls) <?> msg

getTupleParser :: Parser (Parser [ClapiValue])
getTupleParser = sequence <$> many1 (charIn (tdAllTags Wire.cvTaggedData) "type" >>= mkParser)
  where
    mkParser c = do
      let clType = tdTagToEnum Wire.cvTaggedData c
      return $ char ' ' >> cvParser clType

timeParser :: Parser Time
timeParser = do
    s <- decimal
    char ':'
    f <- decimal
    return $ Time s f

attributeeParser :: Parser (Maybe String)
attributeeParser = nothingEmpty <$> (char ' ' >> quotedString)
  where
    nothingEmpty t = case unpack t of
        "" -> Nothing
        s -> Just s

-- FIXME: copy of the one in Serialisation.hs because parser types differ
tdTaggedParser :: TaggedData e a -> (e -> Parser a) -> Parser a
tdTaggedParser td p = do
    t <- satisfy (inClass $ tdAllTags td)
    let te = tdTagToEnum td t
    p te

interpolationParser :: Parser Interpolation
interpolationParser = char ' ' >> tdTaggedParser Wire.interpolationTaggedData p
  where
    p e = case e of
        (ITConstant) -> return IConstant
        (ITLinear) -> return ILinear

msgParser :: Path -> Parser [ClapiValue] -> Parser DataUpdateMessage
msgParser path valParser = tdTaggedParser Wire.dumtTaggedData $ \e -> char ' ' >> case e of
    (Wire.DUMTAdd) -> do
        t <- timeParser
        v <- valParser
        i <- interpolationParser
        a <- attributeeParser
        return $ UMsgAdd path t v i a Nothing
    -- FIXME: just like above
    (Wire.DUMTSet) -> do
        t <- timeParser
        v <- valParser
        i <- interpolationParser
        a <- attributeeParser
        return $ UMsgSet path t v i a Nothing
    (Wire.DUMTRemove) -> do
        t <- timeParser
        a <- attributeeParser
        return $ UMsgRemove path t a Nothing

decode :: Path -> Text -> Either String [DataUpdateMessage]
decode path txt = case parse getTupleParser txt of
    Fail _ ctxs msg -> Left msg
    Partial _ -> Left "Cannot decode empty"
    Done remaining p -> handleResult $ parse ((many1 $ innerParser p) <* endOfInput) remaining
  where
    innerParser tupleParser = char '\n' >> msgParser path tupleParser
    handleResult r = case r of
        Fail _ ctxs msg -> Left $ (show ctxs) ++ " - " ++ msg
        Partial cont -> handleResult $ cont empty
        -- FIXME: nothing should be left over?
        Done _ msgs -> Right msgs
