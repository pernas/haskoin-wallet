{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Network.Haskoin.Wallet.Types
( WalletName
, AccountName
, Wallet(..)
, Account(..)
, PaymentAddress(..)
, AccTx(..)
, TxConfidence(..)
, TxSource(..)
, WalletException(..)
, printWallet
, printAccount
, printAddress
, printAccTx
, Ticker(..)
) where


import Data.Time.Format     (parseTime)
import Data.Time.Clock      (UTCTime)
import System.Locale        (defaultTimeLocale)
import Control.Monad (MonadPlus, mzero, liftM2)
import Control.Exception (Exception)
import Control.Applicative ((<$>),(<*>))

import Data.Int (Int64)
import Data.Typeable (Typeable)
import qualified Data.Text as T
import qualified Data.HashMap.Strict as M
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Aeson
    ( Value (Object, String)
    , FromJSON
    , ToJSON
    , withText
    , withObject
    , (.=)
    , (.:)
    , object
    , parseJSON
    , toJSON
    , encode
    , decode
    )
import Database.Persist.Class
    ( PersistField
    , toPersistValue
    , fromPersistValue 
    )
import Database.Persist.Types (PersistValue(..))
import Database.Persist.Sql (PersistFieldSql, SqlType(..), sqlType)

import Network.Haskoin.Crypto
import Network.Haskoin.Protocol
import Network.Haskoin.Transaction
import Network.Haskoin.Util

type WalletName  = String
type AccountName = String

data WalletException = WalletException String
    deriving (Eq, Read, Show, Typeable)

instance Exception WalletException

data TxConfidence
    = TxOffline
    | TxDead 
    | TxPending
    | TxBuilding
    deriving (Eq, Show, Read)

instance ToJSON TxConfidence where
    toJSON conf = case conf of
        TxOffline  -> "offline"
        TxDead     -> "dead"
        TxPending  -> "pending"
        TxBuilding -> "building"

instance FromJSON TxConfidence where
    parseJSON = withText "TxConfidence" $ \t -> case t of
        "offline"  -> return TxOffline
        "dead"     -> return TxDead
        "pending"  -> return TxPending
        "building" -> return TxBuilding
        _          -> mzero
        
data TxSource
    = NetworkSource
    | WalletSource
    | UnknownSource
    deriving (Eq, Show, Read)

instance ToJSON TxSource where
    toJSON s = case s of
        NetworkSource -> "network"
        WalletSource  -> "wallet"
        UnknownSource -> "unknown"

instance FromJSON TxSource where
    parseJSON = withText "TxSource" $ \t -> case t of
        "network" -> return NetworkSource
        "wallet"  -> return WalletSource
        "unknown" -> return UnknownSource
        _         -> mzero

-- TODO: Add NFData instances for all those types
data Wallet 
    = WalletFull
        { walletName      :: String
        , walletMasterKey :: MasterKey
        } 
    | WalletRead
        { walletName      :: String
        , walletPubKey    :: XPubKey
        }
    deriving (Eq, Show, Read)

instance ToJSON Wallet where
    toJSON (WalletFull n k) = object
        [ "type"   .= String "full"
        , "name"   .= n
        , "master" .= (xPrvExport $ masterKey k)
        ]
    toJSON (WalletRead n k) = object
        [ "type"   .= String "read"
        , "name"   .= n
        , "key"    .= xPubExport k
        ]

instance FromJSON Wallet where
    parseJSON (Object o) = do
        x <- o .: "type"
        n <- o .: "name"
        case x of
            String "full" -> do
                m <- o .: "master" 
                let masterM = loadMasterKey =<< xPrvImport m
                maybe mzero (return . (WalletFull n)) masterM
            String "read" -> do
                k <- o .: "key"
                maybe mzero (return . (WalletRead n)) $ xPubImport k
            _ -> mzero
    parseJSON _ = mzero

printWallet :: Wallet -> String
printWallet w = case w of
    WalletFull n k -> unlines
        [ unwords [ "Wallet    :", n ]
        , unwords [ "Type      :", "Full" ]
        , unwords [ "Master key:", xPrvExport $ masterKey k ]
        ]
    WalletRead n k -> unlines
        [ unwords [ "Wallet     :", n ]
        , unwords [ "Type       :", "Read-only" ]
        , unwords [ "Public key :", xPubExport k ]
        ]

data Account
    = RegularAccount 
        { accountName   :: String
        , accountWallet :: String
        , accountIndex  :: KeyIndex
        , accountKey    :: AccPubKey
        }
    | MultisigAccount
        { accountName     :: String
        , accountWallet   :: String
        , accountIndex    :: KeyIndex
        , accountKey      :: AccPubKey
        , accountRequired :: Int
        , accountTotal    :: Int
        , accountKeys     :: [XPubKey]
        }
    deriving (Eq, Show, Read)

instance ToJSON Account where
    toJSON (RegularAccount n w i k) = object
        [ "type"   .= String "regular"
        , "name"   .= n
        , "wallet" .= w
        , "index"  .= i
        , "key"    .= (xPubExport $ getAccPubKey k)
        ]
    toJSON (MultisigAccount n w i k r t ks) = object
        [ "type"     .= String "multisig"
        , "name"     .= n
        , "wallet"   .= w
        , "index"    .= i
        , "key"      .= (xPubExport $ getAccPubKey k)
        , "required" .= r
        , "total"    .= t
        , "keys"     .= map xPubExport ks
        ]

instance FromJSON Account where
    parseJSON (Object o) = do
        x <- o .: "type"
        n <- o .: "name"
        w <- o .: "wallet"
        i <- o .: "index"
        k <- o .: "key"
        let keyM = loadPubAcc =<< xPubImport k
        case x of
            String "regular" -> 
                maybe mzero (return . (RegularAccount n w i)) keyM
            String "multisig" -> do
                r  <- o .: "required"
                t  <- o .: "total"
                ks <- o .: "keys"
                let keysM      = mapM xPubImport ks
                    f (k',ks') = return $ MultisigAccount n w i k' r t ks'
                maybe mzero f $ liftM2 (,) keyM keysM
            _ -> mzero
    parseJSON _ = mzero

printAccount :: Account -> String
printAccount a = case a of
    RegularAccount n w i k -> unlines
        [ unwords [ "Account:", n ]
        , unwords [ "Wallet :", w ]
        , unwords [ "Type   :", "Regular" ]
        , unwords [ "Tree   :", concat [ "m/",show i,"'/" ] ]
        , unwords [ "Key    :", xPubExport $ getAccPubKey k ]
        ]
    MultisigAccount n w i k r t ks -> unlines $
        [ unwords [ "Account:", n ]
        , unwords [ "Wallet :", w ]
        , unwords [ "Type   :", "Multisig", show r, "of", show t ]
        , unwords [ "Tree   :", concat [ "m/",show i,"'/" ] ]
        , unwords [ "Key    :", xPubExport $ getAccPubKey k ]
        ] ++ if null ks then [] else 
            (unwords [ "3rd Key:", xPubExport $ head ks ]) : 
                (map (\x -> unwords ["        ", xPubExport x]) $ tail ks)

data PaymentAddress = PaymentAddress 
    { paymentAddress :: Address
    , addressLabel   :: String
    , addressIndex   :: KeyIndex
    } deriving (Eq, Show, Read)

instance ToJSON PaymentAddress where
    toJSON (PaymentAddress a l i) = object
        [ "address" .= addrToBase58 a
        , "label"   .= l
        , "index"   .= i
        ]

instance FromJSON PaymentAddress where
    parseJSON (Object o) = do
        a <- o .: "address"
        l <- o .: "label"
        i <- o .: "index"
        let f add = return $ PaymentAddress add l i
        maybe mzero f $ base58ToAddr a
    parseJSON _ = mzero

printAddress :: PaymentAddress -> String
printAddress (PaymentAddress a l i) = unwords $
    [ concat [show i, ":"]
    , addrToBase58 a
    ] ++ if null l then [] else [concat ["(",l,")"]]

data AccTx = AccTx
    { accTxHash          :: TxHash
    , accTxRecipients    :: [Address]
    , accTxValue         :: Int64
    , accTxConfidence    :: TxConfidence
    , accIsCoinbase      :: Bool
    , accTxConfirmations :: Int
    } deriving (Eq, Show, Read)

instance ToJSON AccTx where
    toJSON (AccTx h as v x cb c) = object
        [ "txid"          .= h
        , "recipients"    .= as
        , "value"         .= v
        , "confidence"    .= x
        , "isCoinbase"    .= cb
        , "confirmations" .= c
        ]

instance FromJSON AccTx where
    parseJSON (Object o) = do
        h  <- o .: "txid"
        as <- o .: "recipients"
        v  <- o .: "value"
        x  <- o .: "confidence"
        cb <- o .: "isCoinbase"
        c  <- o .: "confirmations"
        return $ AccTx h as v x cb c
    parseJSON _ = mzero

printAccTx :: AccTx -> String
printAccTx (AccTx h r v ci cb co) = unlines $
    [ unwords [ "Value     :", show v ]
    , unwords [ "Recipients:", addrToBase58 $ head r ]
    ]
    ++
    (map (\x -> unwords ["           ", addrToBase58 x]) $ tail r)
    ++
    [ unwords [ "Confidence:"
              , printConfidence ci
              , concat ["(",show co," confirmations)"] 
              ]
    , unwords [ "TxHash    :", encodeTxHashLE h ]
    ] ++ if cb then [unwords ["Coinbase  :", "Yes"]] else []

printConfidence :: TxConfidence -> String
printConfidence c = case c of
    TxBuilding -> "Building"
    TxPending  -> "Pending"
    TxDead     -> "Dead"
    TxOffline  -> "Offline"

persistTextErrMsg :: T.Text
persistTextErrMsg = "Has to be a PersistText"
persistBSErrMsg :: T.Text 
persistBSErrMsg = "Has to be a PersistByteString" 

toPersistJson :: (ToJSON a) => a -> PersistValue
toPersistJson = PersistText . decodeUtf8 . toStrict . encode

fromPersistJson :: (FromJSON a) => T.Text -> PersistValue -> Either T.Text a
fromPersistJson msg (PersistText w) = 
    maybeToEither msg (decode . fromStrict $ encodeUtf8 w)
fromPersistJson _ _ = Left persistTextErrMsg

instance PersistField Address where
    toPersistValue = PersistText . T.pack . addrToBase58
    fromPersistValue (PersistText a) = 
        maybeToEither "Not a valid Address" . base58ToAddr $ T.unpack a
    fromPersistValue _ = Left persistTextErrMsg

instance PersistFieldSql Address where
    sqlType _ = SqlString

instance PersistField [Address] where
    toPersistValue = toPersistJson
    fromPersistValue = fromPersistJson "Not a valid Address list"

instance PersistFieldSql [Address] where
    sqlType _ = SqlString

instance PersistField TxHash where
    toPersistValue = PersistText . T.pack . encodeTxHashLE
    fromPersistValue (PersistText h) =
        maybeToEither "Not a valid TxHash" (decodeTxHashLE $ T.unpack h)
    fromPersistValue _ = Left persistTextErrMsg

instance PersistFieldSql TxHash where
    sqlType _ = SqlString

instance PersistField BlockHash where
    toPersistValue = PersistText . T.pack . encodeBlockHashLE
    fromPersistValue (PersistText h) =
        maybeToEither "Not a valid BlockHash" (decodeBlockHashLE $ T.unpack h)
    fromPersistValue _ = Left persistTextErrMsg

instance PersistFieldSql BlockHash where
    sqlType _ = SqlString

instance PersistField Wallet where
    toPersistValue = toPersistJson
    fromPersistValue = fromPersistJson "Not a valid Wallet"

instance PersistFieldSql Wallet where
    sqlType _ = SqlString

instance PersistField Account where
    toPersistValue = toPersistJson
    fromPersistValue = fromPersistJson "Not a valid Account"

instance PersistFieldSql Account where
    sqlType _ = SqlString

instance PersistField TxConfidence where
    toPersistValue tc = PersistText $ decodeUtf8 $ stringToBS $ case tc of
        TxOffline  -> "offline"
        TxDead     -> "dead"
        TxPending  -> "pending"
        TxBuilding -> "building"

    fromPersistValue (PersistText t) = case bsToString $ encodeUtf8 t of
        "offline"  -> return TxOffline
        "dead"     -> return TxDead
        "pending"  -> return TxPending
        "building" -> return TxBuilding
        _          -> Left "Not a valid TxConfidence"
    fromPersistValue _ = Left "Not a valid TxConfidence"
        
instance PersistFieldSql TxConfidence where
    sqlType _ = SqlString

instance PersistField TxSource where
    toPersistValue ts = PersistText $ decodeUtf8 $ stringToBS $ case ts of
        NetworkSource -> "network"
        WalletSource  -> "wallet"
        UnknownSource -> "unknown"

    fromPersistValue (PersistText t) = case bsToString $ encodeUtf8 t of
        "network" -> return NetworkSource
        "wallet"  -> return WalletSource
        "unknown" -> return UnknownSource
        _         -> Left "Not a valid TxSource"
    fromPersistValue _ = Left "Not a valid TxSource"

instance PersistFieldSql TxSource where
    sqlType _ = SqlString

instance PersistField Coin where
    toPersistValue = toPersistJson
    fromPersistValue = fromPersistJson "Not a valid Coin"

instance PersistFieldSql Coin where
    sqlType _ = SqlString

instance PersistField OutPoint where
    toPersistValue = PersistText . decodeUtf8 . stringToBS . bsToHex . encode'
    fromPersistValue (PersistText t) = maybeToEither "Not a valid OutPoint" $
        decodeToMaybe =<< (hexToBS $ bsToString $ encodeUtf8 t)
    fromPersistValue _ = Left "Not a valid OutPoint"

instance PersistFieldSql OutPoint where
    sqlType _ = SqlString

instance PersistField Tx where
    toPersistValue = PersistByteString . encode'
    fromPersistValue (PersistByteString bs) = case txE of
        Right tx -> Right tx
        Left str -> Left $ T.pack str
      where
        txE = decodeToEither bs
    fromPersistValue _ = Left persistBSErrMsg

instance PersistFieldSql Tx where
    sqlType _ = SqlBlob

data Ticker = Ticker
    { getAvg24    :: Double
    , getAsk      :: Double
    , getBid      :: Double
    , getLast     :: Double
    , getTime     :: UTCTime
    , getVol      :: Double
    } deriving (Show, Eq)

instance FromJSON Ticker where
    parseJSON (Object o) =
      Ticker                                  <$>
        (o .: "24h_avg")                      <*>
        (o .: "ask")                          <*>
        (o .: "bid")                          <*>
        (o .: "last")                         <*>
        (parseDate =<< (o .: "timestamp"))    <*>
        (o .: "total_vol")
    parseJSON _ = mzero
    
instance FromJSON (M.HashMap T.Text Ticker) where
  parseJSON = withObject "tickers" $ \o -> M.traverseWithKey f (g o) where
      f _ = parseJSON
      g = M.delete "timestamp"

parseDate :: (MonadPlus m) => String -> m UTCTime
parseDate y = case parseTime defaultTimeLocale "%a, %d %b %Y %T %z" y of
    Nothing -> mzero
    Just x -> return x
