--------------------------------------------------------------------------------
-- | Lightweight abstraction over an input/output stream.
{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
module Network.WebSockets.Stream
    ( Stream
    , makeStream
    , makeSocketStream
    , makeEchoStream
    , parse
    , parseBin
    , write
    , close
    ) where

import           Control.Concurrent             (modifyMVar, modifyMVar_)
import           Control.Concurrent.MVar        (newEmptyMVar, newMVar,
                                                 putMVar, takeMVar, withMVar)
import           Control.Exception              (throwIO, try, onException,
                                                 SomeException(..))
import           Control.Monad                  (forM_)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.State.Strict     (runStateT)
import qualified Data.Attoparsec.ByteString     as Atto
import qualified Data.Binary.Get                as BIN
import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as BL
import qualified Pipes                          as P
import           Pipes                          ((>->))
import qualified Pipes.Binary                   as P
import qualified Pipes.ByteString               as P
import qualified Pipes.Parse                    as P
import qualified Pipes.Attoparsec               as P
import qualified Pipes.Network.TCP              as P
import qualified Network.Socket                 as S
import           Data.IORef                     (newIORef, writeIORef)
import           Network.WebSockets.Types       (ConnectionException(..))


--------------------------------------------------------------------------------
-- | Lightweight abstraction over an input/output stream.
data Stream = Stream
    { streamParse :: forall a. P.Parser B.ByteString IO a -> IO a
    , streamWrite :: BL.ByteString -> IO ()
    , streamClose :: IO ()
    }

--------------------------------------------------------------------------------
-- | Create a stream from a "receive" and "send" action. The following
-- properties apply:
--
-- - Regardless of the provided "receive" and "send" functions, reading and
--   writing from the stream will be thread-safe, i.e. this function will create
--   a receive and write lock to be used internally.
--
-- - Reading from or writing or to a closed 'Stream' will always throw an
--   exception, even if the underlying "receive" and "send" functions do not
--   (we do the bookkeeping).
--
-- - Streams should always be closed.
makeStream
    :: IO (Maybe B.ByteString)         -- ^ Reading
    -> (Maybe BL.ByteString -> IO ())  -- ^ Writing
    -> IO Stream                       -- ^ Resulting stream
makeStream receive send = do
  closeRef <- newIORef (return ())
  let receiveP = do
        bytes <- liftIO $ try receive
        case bytes of
          Right Nothing -> return ()
          Right (Just bs) -> P.yield bs >> receiveP
          Left (SomeException _) -> liftIO $ throwIO ConnectionClosed
  r <- newMVar receiveP
  w <- newMVar send
  let parser p = do
        modifyMVar r $ \rp -> do
            (out, rp') <- runStateT p rp
            return $ (rp', out)
      closer = do 
        modifyMVar_ w $ \_ -> do
          modifyMVar_ r $ \_ -> do
            return $ liftIO $ throwIO ConnectionClosed
          return (\_ -> throwIO ConnectionClosed)
        send Nothing
  writeIORef closeRef closer
  return $ Stream
    { streamParse = parser
    , streamWrite = \s -> do
      withMVar w $ \writer -> do
        onException (writer $ Just s) closer
    , streamClose = closer
    }

--------------------------------------------------------------------------------
makeSocketStream :: S.Socket -> IO Stream
makeSocketStream socket = do
  let producer = P.fromSocket socket 4096
  prodRef <- newMVar producer
  let consumer = P.toSocket socket
      parseStream p = modifyMVar prodRef $ \pr -> do
        (res, pr') <- P.runStateT p pr
        return (pr', res)
      writeStream b = P.runEffect (P.fromLazy b >-> consumer)
      closeStream = do
        modifyMVar_ prodRef (\_ -> return (return ()))
        S.close socket
  return $ Stream
    { streamParse = parseStream
    , streamWrite = writeStream
    , streamClose = closeStream
    }


--------------------------------------------------------------------------------
makeEchoStream :: IO Stream
makeEchoStream = do
    mvar <- newEmptyMVar
    makeStream (takeMVar mvar) $ \mbBs -> case mbBs of
        Nothing -> putMVar mvar Nothing
        Just bs -> forM_ (BL.toChunks bs) $ \c -> putMVar mvar (Just c)

--------------------------------------------------------------------------------
parseBin :: Stream -> BIN.Get a -> IO (Maybe a)
parseBin stream parser = do
  a <- streamParse stream $ P.decodeGet parser
  case a of
    (Left e) -> throwIO e
    (Right v) -> return $ Just v

parse :: Stream -> Atto.Parser a -> IO (Maybe a)
parse stream parser = do
  a <- streamParse stream (P.parse parser)
  case a of
    Just (Left e) -> throwIO e
    Just (Right v) -> return $ Just v
    Nothing -> return Nothing


--------------------------------------------------------------------------------
write :: Stream -> BL.ByteString -> IO ()
write stream = streamWrite stream

--------------------------------------------------------------------------------
close :: Stream -> IO ()
close stream = streamClose stream
