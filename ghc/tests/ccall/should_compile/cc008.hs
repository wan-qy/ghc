-- !!! cc008 -- foreign export dynamic returning newtype of Addr
module Test where

import Addr

newtype Ptr a = Ptr Addr

foreign export dynamic mkFoo :: IO () -> IO (Ptr Int)
