module Red14.Reduceron where

import Lava
import Monad
import CircLib.Bit
import CircLib.Word
import CircLib.Common
import CircLib.RTL
import CircLib.OffsetReg
import Red14.ProcState
import Red14.Mem
import Red14.Bytecode
import Red14.Collect
import Red14.Compat

reduceron :: ProcState -> RTL ()
reduceron s = initialise s >> loop (step s)

initialise :: ProcState -> RTL ()
initialise s =  do reg (sp s) <-- maxStkAddr
                   top s <-- mkFunNode (word 0)
                   tick

readTop8 :: ProcState -> RTL [Word]
readTop8 s =
  do let valA = memDatIn (stackA s)
     let valB = memDatIn (stackB s)
     return $ groupN wordSize (valA ++ valB)

step :: ProcState -> RTL ()
step s =
  do t <- readVar (top s)
     stkPtr <- readVar (reg (sp s))

     let fun  = isFunNode t
     let func = fun <&> inv (isPrim t)
     let prim = fun <&> isPrim t

     b <- heapCheck s
     onlyIf b (collect s)

     let fin = tree (<&>) stkPtr

     choose
       [ isIntNode t --> do status s <-- statusInt
                            handleInt s t fin
       , prim        --> do status s <-- statusPrim
                            handlePrim s t fin
       , func        --> do status s <-- statusUnfold
                            unfold s t
       , isApNode t  --> do status s <-- statusUnwind
                            unwind s
       ]

heapCheck :: ProcState -> RTL Bit
heapCheck s = do heapPtr <- readVar (reg (hp s))
                 return (tree (<&>) (drop 7 heapPtr))

handleInt :: ProcState -> Word -> Bit -> RTL ()
handleInt s t fin =
  do stackPtr <- readVar (reg (sp s))
     top8 <- readTop8 s
     let t1 = top8 !! 0

     choose
       [ fin     --> do r0 s <-- (t `shre` 3)
                        tick
                        status s <-- statusHalted
                        stop

       , inv fin --> do tick
                        octoRead (heapA s, heapB s) (drop 3 t1)
                        (top s) <-- t1
                        quadWrite (stackA s)
                                  (t:replicate 3 (replicate wordSize low))
                                  [high,low,low,low]
                                  (stackPtr /+/ stkAddress 1)
                        quadRead (stackB s) (stackPtr /+/ stkAddress 5)
                        tick
       ]

handlePrim :: ProcState -> Word -> Bit -> RTL ()
handlePrim s t fin =
  do tick
     tops <- readTop8 s
     valTop <- readVar (top s)
     stkPtr <- readVar (reg (sp s))
     result <- readVar (r1 s)
     [wasArith] <- readVar (bit1 s)

     let a = (tops !! 0) `shre` 3
     let b = (tops !! 1) `shre` 3

     let resEq = a /=/ b
         resNotEq = inv resEq
         resLessEq = a /<=/ b
         arith = isAdd t <|> isSub t
         res = isAdd t ? (a /+/ b, a /-/ b)

     let resTrue  =  (isEq t <&> resEq)
                 <|> (isNotEq t <&> resNotEq)
                 <|> (isLessEq t <&> resLessEq)

     let incr = (arith ? (2 `ofWidth` 3, 4 `ofWidth` 3)) ++ [low]
     let newTop = arith ? (tops !! 2, resTrue ? (tops !! 2, tops !! 3))
     top s <-- newTop
     reg (sp s) <-- (stkPtr /+/ incr)
     r1 s <-- (arith ? (mkIntNode res, resTrue ? (trueAddr, falseAddr)))
     bit1 s <-- [arith]
     r <- readAStk s (stkPtr /+/ (2 `ofWidth` 3))
     tick

     let addrA = stkPtr /+/ stkAddress 1
         addrB = stkPtr /+/ stkAddress 5
     quadWrite (stackA s)
               (result:replicate 3 (replicate wordSize low))
               [wasArith,low,low,low]
               addrA
     quadRead (stackB s) addrB
     octoRead (heapA s, heapB s) (drop 3 valTop)

     onlyIf (wasArith <&> fin) (top s <-- result)

     r2 s <-- r
     root <- readVar (r2 s)

     tick

     onlyIf (head root) $
       writeMem s (markEnd [high] result)
                  (take addrWidth (tail root))


unwind :: ProcState -> RTL ()
unwind s =
  do stkPtr <- readVar (reg (sp s))
     t <- readVar (top s)
     let nodes = groupN 18 (memDatIn (heapA s) ++ memDatIn (heapB s))
     let endMarked = onlyFirst (map isEnd nodes)
     let len = encode endMarked
     let len' = len ++ replicate (stkAddrWidth - 3) low
     let stkPtr' = stkPtr /-/ len'
     let root = drop 3 t
     let addrs = map (\i -> mkAStkAddr (root /+/ (i `ofWidth` 5))) [0..7]
     let msk = tally (map isEnd nodes)
     let nodes' = rotateRight' endMarked (reverse nodes)
     let newTop = last nodes'

     a2 s <-- ((stkPtr /+/ stkAddress 1) ++ replicate 3 low)
     a3 s <-- ((stkPtr /+/ stkAddress 5) ++ replicate 3 low)
     stkPtr1 <- liftM (take stkAddrWidth) (readVar (a2 s))
     stkPtr5 <- liftM (take stkAddrWidth) (readVar (a3 s))
     tick

     quadWrite (stackA s) (take 4 nodes') (take 4 msk)
               (stkPtr1 /-/ len')
     quadWrite (stackB s) (drop 4 nodes') (drop 4 msk)
               (stkPtr5 /-/ len')

     octoWrite (astackA s, astackB s)
               (reverse addrs)
               (stkPtr /-/ stkAddress 7)
     octoRead (heapA s, heapB s) (drop 3 newTop)
     top s <-- newTop
     reg (sp s) <-- stkPtr'
     tick


inst :: ProcState -> Word -> RTL Word
inst s node = 
  do let end = [isEnd node]
     base <- readVar (a1 s)
     tops <- mapM readVar (stkBuf s)

     let argNum  = take 3 (getArg node)
         arg     = select (decode argNum) tops
         ap      = base /+/ (getAp node /-/ (1 `ofWidth` addrWidth))
         isArg   = isArgNode node
         isAp    = isApNode node
         isOther = isFunNode node <|> isIntNode node

         trArg   = markEnd end arg
         trAp    = markEnd end (mkApNode ap)

         output  = select ([isArg] ++ [isAp] ++ [isOther]) [trArg, trAp, node]

     return output
     
unfold :: ProcState -> Word -> RTL ()
unfold s tp =
  do let initialAddr = take combAddrWidth (drop 4 tp)
     tops <- readTop8 s
     heapPtr <- readVar (reg (hp s))
     a1 s <-- heapPtr
     root <- readVar (r1 s)
     base <- readVar (a1 s)
     ca0 s <-- (initialAddr /+/ combAddress 8)
     addr <- readVar (ca0 s)
     size <- readVar (dec0 s)
     stkPtr <- readVar (reg (sp s))
     heapPtr' <- readVar (a0 s)

     code <- octoRead (codeA s, codeB s) initialAddr
     code' <- mapM (inst s) code
     tick  -- REMOVE!
     zipWithM (<--) (stkBuf s) tops
     octoRead (codeA s, codeB s) addr
     ca0 s <-- (addr /+/ combAddress 8)
     tick

     let (numArgs, spineLen, sz) = extract (code !! 0)

     let stkPtr' = stkPtr /+/ (numArgs ++ [low])
     sa0 s <-- stkPtr'
     stkPtr2 <- readVar (sa0 s)
     reg (sp s) <-- (stkPtr' /-/ (spineLen ++ [low]))
     r <- readAStk s stkPtr'

     --
     top s <-- select (decode (take 3 spineLen)) (rotl 1 code')
     --
     octoWrite (heapA s, heapB s) (rotl 1 code') heapPtr


     --
     let spine = reverse (rotl 1 code')
     let spineAddr = stkPtr' /-/ stkAddress 7
     octoWrite (stackA s, stackB s) spine spineAddr
     --

     dec0 s <-- (sz /-/ (7 `ofWidth` 10))
     let hpInitIncr = wordMin sz (7 `ofWidth` 10)
     reg (hp s) <-- (heapPtr /+/ hpInitIncr)

     octoRead (codeA s, codeB s) addr
     ca0 s <-- (addr /+/ combAddress 8)
     tick

     let hpIncr = wordMin size (8 `ofWidth` 10)
     r1 s <-- r
     
     -- 
     let addrs = map (\i -> mkAStkAddr (base /+/ (i `ofWidth` 5))) [0..7]
     octoWrite (astackA s, astackB s) (reverse addrs)
                                          (stkPtr2 /-/ stkAddress 7)
     --

     while (address 0 /</ size) $
       do octoWrite (heapA s, heapB s) code' heapPtr
          octoRead (codeA s, codeB s) addr
          reg (hp s) <-- (heapPtr /+/ hpIncr)
          ca0 s <-- (addr /+/ combAddress 8)
          dec0 s <-- (size /-/ (8 `ofWidth` 10))
          tick

     --
     t <- readVar (top s)
     octoRead (heapA s, heapB s) (drop 3 t)
     octoRead (stackA s, stackB s) (stkPtr /+/ stkAddress 1)
     --

     tick

     status s <-- statusUnwind
     onlyIf (head root) $
       do writeMem s (mkApEndNode base)
                     (take addrWidth (tail root))
  where
    extract start = (numArgs, spineLen, size)
      where
        spineLen = drop 14 start
        size = take 10 (drop 4 start)
        numArgs = take 4 start