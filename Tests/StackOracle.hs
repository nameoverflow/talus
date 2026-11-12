import qualified XMonad.StackSet as W
import Data.List (intercalate)
main :: IO ()
main = mapM_ test [1..12]
  where
    initial n = foldr W.insertUp (W.new () ["1"] [()] :: W.StackSet String () Int Int ()) [1..n]
    render s = intercalate "," (map show (W.index s)) ++ ":" ++ show (W.peek s)
    test n = mapM_ (putStrLn . render) [W.swapUp (initial n), W.swapDown (W.focusUp (initial n))]
