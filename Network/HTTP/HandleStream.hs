-----------------------------------------------------------------------------
-- |
-- Module      :  Network.HTTP.HandleStream
-- Copyright   :  (c) Warrick Gray 2002, Bjorn Bringert 2003-2005, 2007 Robin Bate Boerop, 2008 Sigbjorn Finne
-- License     :  BSD
-- 
-- Maintainer  :  Sigbjorn Finne <sigbjorn.finne@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (not tested)
--
-- A HandleStream version of Network.HTTP.Stream's public offerings.
--
-----------------------------------------------------------------------------
module Network.HTTP.HandleStream 
       ( simpleHTTP      -- :: Request ty -> IO (Result (Response ty))
       , simpleHTTP_     -- :: HStream ty => HandleStream ty -> Request ty -> IO (Result (Response ty))
       , sendHTTP        -- :: HStream ty => HandleStream ty -> Request ty -> IO (Result (Response ty))
       , sendHTTP_notify -- :: HStream ty => HandleStream ty -> Request ty -> IO () -> IO (Result (Response ty))
       , receiveHTTP     -- :: HStream ty => HandleStream ty -> IO (Result (Request ty))
       , respondHTTP     -- :: HStream ty => HandleStream ty -> Response ty -> IO ()
       
       , simpleHTTP_debug -- :: FilePath -> Request DebugString -> IO (Response DebugString)
       ) where

-----------------------------------------------------------------
------------------ Imports --------------------------------------
-----------------------------------------------------------------

import Network.BufferType
import Network.Stream ( fmapE, Result )
import Network.StreamDebugger ( debugByteStream )
import Network.TCP (HStream(..), HandleStream )

import Network.HTTP.Base
import Network.HTTP.Headers
import Network.HTTP.Utils ( trim )

import Data.Char (toLower)
import Data.Maybe (fromMaybe)
import Control.Monad (when)

-----------------------------------------------------------------
------------------ Misc -----------------------------------------
-----------------------------------------------------------------

-- | Simple way to get a resource across a non-persistant connection.
-- Headers that may be altered:
--  Host        Altered only if no Host header is supplied, HTTP\/1.1
--              requires a Host header.
--  Connection  Where no allowance is made for persistant connections
--              the Connection header will be set to "close"
simpleHTTP :: HStream ty => Request ty -> IO (Result (Response ty))
simpleHTTP r = do 
  auth <- getAuth r
  c <- openStream (host auth) (fromMaybe 80 (port auth))
  simpleHTTP_ c r

simpleHTTP_debug :: HStream ty => FilePath -> Request ty -> IO (Result (Response ty))
simpleHTTP_debug httpLogFile r = do 
  auth <- getAuth r
  c0   <- openStream (host auth) (fromMaybe 80 (port auth))
  c    <- debugByteStream httpLogFile c0
  simpleHTTP_ c r

-- | Like 'simpleHTTP', but acting on an already opened stream.
simpleHTTP_ :: HStream ty => HandleStream ty -> Request ty -> IO (Result (Response ty))
simpleHTTP_ s r = sendHTTP s r

sendHTTP :: HStream ty => HandleStream ty -> Request ty -> IO (Result (Response ty))
sendHTTP conn rq = sendHTTP_notify conn rq (return ())

sendHTTP_notify :: HStream ty
                => HandleStream ty
		-> Request ty
		-> IO ()
		-> IO (Result (Response ty))
sendHTTP_notify conn rq onSendComplete = do
  rsp <- catchIO (sendMain conn rq onSendComplete)
                 (\e -> do { close conn; ioError e })
  let fn list = when (or $ map findConnClose list)
                     (close conn)
  either (\_ -> fn [rqHeaders rq])
         (\r -> fn [rqHeaders rq,rspHeaders r])
         rsp
  return rsp

-- From RFC 2616, section 8.2.3:
-- 'Because of the presence of older implementations, the protocol allows
-- ambiguous situations in which a client may send "Expect: 100-
-- continue" without receiving either a 417 (Expectation Failed) status
-- or a 100 (Continue) status. Therefore, when a client sends this
-- header field to an origin server (possibly via a proxy) from which it
-- has never seen a 100 (Continue) status, the client SHOULD NOT wait
-- for an indefinite period before sending the request body.'
--
-- Since we would wait forever, I have disabled use of 100-continue for now.
sendMain :: HStream ty
         => HandleStream ty
	 -> Request ty
	 -> (IO ())
	 -> IO (Result (Response ty))
sendMain conn rqst onSendComplete = do
      --let str = if null (rqBody rqst)
      --              then show rqst
      --              else show (insertHeader HdrExpect "100-continue" rqst)
  writeBlock conn (buf_fromStr bufferOps $ show rqst)
    -- write body immediately, don't wait for 100 CONTINUE
  writeBlock conn (rqBody rqst)
  onSendComplete
  rsp <- getResponseHead conn
  switchResponse conn True False rsp rqst

   -- Hmmm, this could go bad if we keep getting "100 Continue"
   -- responses...  Except this should never happen according
   -- to the RFC.

switchResponse :: HStream ty
               => HandleStream ty
	       -> Bool {- allow retry? -}
               -> Bool {- is body sent? -}
               -> Result ResponseData
               -> Request ty
               -> IO (Result (Response ty))
switchResponse _ _ _ (Left e) _ = return (Left e)
                -- retry on connreset?
                -- if we attempt to use the same socket then there is an excellent
                -- chance that the socket is not in a completely closed state.

switchResponse conn allow_retry bdy_sent (Right (cd,rn,hdrs)) rqst = 
   case matchResponse (rqMethod rqst) cd of
     Continue
      | not bdy_sent -> do {- Time to send the body -}
        writeBlock conn (rqBody rqst) >>= either (return . Left)
	   (\ _ -> do
              rsp <- getResponseHead conn
              switchResponse conn allow_retry True rsp rqst)
      | otherwise    -> do {- keep waiting -}
        rsp <- getResponseHead conn
        switchResponse conn allow_retry bdy_sent rsp rqst

     Retry -> do {- Request with "Expect" header failed.
                    Trouble is the request contains Expects
                    other than "100-Continue" -}
        writeBlock conn ((buf_append bufferOps)
		                     (buf_fromStr bufferOps (show rqst))
			             (rqBody rqst))
        rsp <- getResponseHead conn
        switchResponse conn False bdy_sent rsp rqst
                     
     Done -> return (Right $ Response cd rn hdrs (buf_empty bufferOps))

     DieHorribly str -> return (responseParseError "Invalid response:" str)
     ExpectEntity -> 
       fmapE (\ (ftrs,bdy) -> Right (Response cd rn (hdrs++ftrs) bdy)) $
        maybe (maybe (hopefulTransfer bo (readLine conn) [])
	             (\ x -> 
		        readsOne (linearTransfer (readBlock conn))
		                 (return$responseParseError "unrecognized content-length value" x)
				 x)
		     cl)
	      (ifChunked (chunkedTransfer bo (readLine conn) (readBlock conn))
	                 (uglyDeathTransfer "sendHTTP"))
              tc
      where
       tc = lookupHeader HdrTransferEncoding hdrs
       cl = lookupHeader HdrContentLength hdrs
       bo = bufferOps
                    
-- reads and parses headers
getResponseHead :: HStream ty => HandleStream ty -> IO (Result ResponseData)
getResponseHead conn = 
   fmapE (\es -> parseResponseHead (map (buf_toStr bufferOps) es))
         (readTillEmpty1 bufferOps (readLine conn))

-- | Receive and parse a HTTP request from the given Stream. Should be used 
--   for server side interactions.
receiveHTTP :: HStream bufTy => HandleStream bufTy -> IO (Result (Request bufTy))
receiveHTTP conn = getRequestHead >>= either (return . Left) processRequest
  where
    -- reads and parses headers
   getRequestHead :: IO (Result RequestData)
   getRequestHead = do
      fmapE (\es -> parseRequestHead (map (buf_toStr bufferOps) es))
            (readTillEmpty1 bufferOps (readLine conn))
	
   processRequest (rm,uri,hdrs) =
      fmapE (\ (ftrs,bdy) -> Right (Request uri rm (hdrs++ftrs) bdy)) $
	     maybe 
	      (maybe (return (Right ([], buf_empty bo))) -- hopefulTransfer ""
	             (\ x -> readsOne (linearTransfer (readBlock conn))
			              (return$responseParseError "unrecognized Content-Length value" x)
				      x)
				      
		     cl)
  	      (ifChunked (chunkedTransfer bo (readLine conn) (readBlock conn))
	                 (uglyDeathTransfer "receiveHTTP"))
              tc
    where
     -- FIXME : Also handle 100-continue.
     tc = lookupHeader HdrTransferEncoding hdrs
     cl = lookupHeader HdrContentLength hdrs
     bo = bufferOps

-- | Very simple function, send a HTTP response over the given stream. This 
--   could be improved on to use different transfer types.
respondHTTP :: HStream ty => HandleStream ty -> Response ty -> IO ()
respondHTTP conn rsp = do 
  writeBlock conn (buf_fromStr bufferOps $ show rsp)
   -- write body immediately, don't wait for 100 CONTINUE
  writeBlock conn (rspBody rsp)
  return ()

------------------------------------------------------------------------------

readsOne :: Read a => (a -> b) -> b -> String -> b
readsOne f n str = 
 case reads str of
   ((v,_):_) -> f v
   _ -> n

headerName :: String -> String
headerName x = map toLower (trim x)

ifChunked :: a -> a -> String -> a
ifChunked a b s = 
  case headerName s of
    "chunked" -> a
    _ -> b

