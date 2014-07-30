{-|
  This package provides a command line application called /hw/ (haskoin
  wallet). It is a lightweight bitcoin wallet featuring BIP32 key management,
  deterministic signatures (RFC-6979) and first order support for
  multisignature transactions. A library API for /hw/ is also exposed.
-}
module Network.Haskoin.Wallet
( 
-- *Wallet Commands
  Wallet(..)
, initWalletDB
, newWalletMnemo
, newWallet
, walletList
, insertTickerDB

-- *Account Commands
, Account(..)
, AccountName
, getAccount
, newAccount
, newMSAccount
, addAccountKeys
, accountList
, accountPrvKey
, isMSAccount

-- *Address Commands
, PaymentAddress(..)
, getAddress
, addressList
, addressCount
, addressPage
, newAddrs
, setAddrLabel
, setLookAhead
, addressPrvKey

-- *Coin Commands
, balance
, unspentCoins
, spendableCoins

-- *Tx Commands
, AccTx(..) 
, getTx
, txList
, txPage
, importTx
, removeTx
, sendTx
, signWalletTx
, walletBloomFilter
, isTxInWallet
, firstKeyTime

-- *Block Commands
, importBlocks

-- *Database Types 
, TxConfidence(..)
, TxSource(..)
, WalletException(..)

) where

import Network.Haskoin.Wallet.Root
import Network.Haskoin.Wallet.Account
import Network.Haskoin.Wallet.Address
import Network.Haskoin.Wallet.Tx
import Network.Haskoin.Wallet.Types

