{-# LANGUAGE RankNTypes #-}
--------------------------------------------------------------------------------
module Network.WebSockets.Tests.Util
    ( ArbitraryUtf8 (..)
    , arbitraryUtf8
    , arbitraryByteString
    , withEchoStream
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative      ((<$>))
import qualified Data.ByteString.Lazy     as BL
import qualified Data.Text.Lazy           as TL
import qualified Data.Text.Lazy.Encoding  as TL
import           Test.QuickCheck          (Arbitrary (..), Gen)

import Data.Attoparsec.ByteString (Parser)
import Blaze.ByteString.Builder (Builder)
import qualified Blaze.ByteString.Builder as Builder
import Pipes (liftIO)
import qualified Pipes.Parse as P
import qualified Pipes.Attoparsec as P
import qualified Pipes.ByteString as P
import Control.Concurrent.STM
import Control.Concurrent.STM.TMChan
import Control.Exception
import Control.Concurrent.MVar

--------------------------------------------------------------------------------
import           Network.WebSockets.Types


--------------------------------------------------------------------------------
newtype ArbitraryUtf8 = ArbitraryUtf8 {unArbitraryUtf8 :: BL.ByteString}
    deriving (Eq, Ord, Show)


--------------------------------------------------------------------------------
instance Arbitrary ArbitraryUtf8 where
    arbitrary = ArbitraryUtf8 <$> arbitraryUtf8


--------------------------------------------------------------------------------
arbitraryUtf8 :: Gen BL.ByteString
arbitraryUtf8 = toLazyByteString . TL.encodeUtf8 . TL.pack <$> arbitrary


--------------------------------------------------------------------------------
arbitraryByteString :: Gen BL.ByteString
arbitraryByteString = BL.pack <$> arbitrary


withEchoStream :: ((forall a. Parser a -> IO (Maybe a))
                   -> (Builder -> IO ())
                   -> IO ()
                   -> IO r)
               -> IO r
withEchoStream k = do
  echo <- newTMChanIO
  let producer = do
        r <- liftIO (atomically (readTMChan echo))
        case r of
          Nothing -> return ()
          Just x  -> P.fromLazy x >> producer
  prodRef <- newMVar producer

  let parseStream p = do pr <- takeMVar prodRef
                         (res,pr') <- P.runStateT (P.parse p) pr
                         putMVar prodRef pr'
                         case res of
                           Nothing -> return Nothing
                           Just (Left e) -> throwIO e
                           Just (Right x) -> return (Just x)
      writeStream b = atomically (writeTMChan echo (Builder.toLazyByteString b))
      closeStream = do
        atomically (closeTMChan echo)

  k parseStream writeStream closeStream