%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[HsBinds]{Abstract syntax: top-level bindings and signatures}

Datatype for: @HsBinds@, @Bind@, @Sig@, @MonoBinds@.

\begin{code}
module HsBinds where

#include "HsVersions.h"

import {-# SOURCE #-} HsExpr    ( pprExpr, HsExpr )
import {-# SOURCE #-} HsMatches ( pprMatches, Match, pprGRHSs, GRHSs )

-- friends:
import HsTypes		( HsType )
import CoreSyn		( CoreExpr )
import PprCore		()	   -- Instances for Outputable

--others:
import Id		( Id )
import BasicTypes	( RecFlag(..), Fixity )
import Outputable	
import Bag
import SrcLoc		( SrcLoc )
import Var		( TyVar )
\end{code}

%************************************************************************
%*									*
\subsection{Bindings: @HsBinds@}
%*									*
%************************************************************************

The following syntax may produce new syntax which is not part of the input,
and which is instead a translation of the input to the typechecker.
Syntax translations are marked TRANSLATION in comments. New empty
productions are useful in development but may not appear in the final
grammar.

Collections of bindings, created by dependency analysis and translation:

\begin{code}
data HsBinds id pat		-- binders and bindees
  = EmptyBinds

  | ThenBinds	(HsBinds id pat)
		(HsBinds id pat)

  | MonoBind 	(MonoBinds id pat)
		[Sig id]		-- Empty on typechecker output
		RecFlag
\end{code}

\begin{code}
nullBinds :: HsBinds id pat -> Bool

nullBinds EmptyBinds		= True
nullBinds (ThenBinds b1 b2)	= nullBinds b1 && nullBinds b2
nullBinds (MonoBind b _ _)	= nullMonoBinds b
\end{code}

\begin{code}
instance (Outputable pat, Outputable id) =>
		Outputable (HsBinds id pat) where
    ppr binds = ppr_binds binds

ppr_binds EmptyBinds = empty
ppr_binds (ThenBinds binds1 binds2)
     = ($$) (ppr_binds binds1) (ppr_binds binds2)
ppr_binds (MonoBind bind sigs is_rec)
     = vcat [ifNotPprForUser (ptext rec_str),
     	     vcat (map ppr sigs),
	     ppr bind
       ]
     where
       rec_str = case is_rec of
		   Recursive    -> SLIT("{- rec -}")
		   NonRecursive -> SLIT("{- nonrec -}")
\end{code}

%************************************************************************
%*									*
\subsection{Bindings: @MonoBinds@}
%*									*
%************************************************************************

Global bindings (where clauses)

\begin{code}
data MonoBinds id pat
  = EmptyMonoBinds

  | AndMonoBinds    (MonoBinds id pat)
		    (MonoBinds id pat)

  | PatMonoBind     pat
		    (GRHSs id pat)
		    SrcLoc

  | FunMonoBind     id
		    Bool			-- True => infix declaration
		    [Match id pat]
		    SrcLoc

  | VarMonoBind	    id			-- TRANSLATION
		    (HsExpr id pat)

  | CoreMonoBind    id			-- TRANSLATION
		    CoreExpr		-- No zonking; this is a final CoreExpr with Ids and Types!

  | AbsBinds			-- Binds abstraction; TRANSLATION
		[TyVar]	  -- Type variables
		[id]			  -- Dicts
		[([TyVar], id, id)]  -- (type variables, polymorphic, momonmorphic) triples
		(MonoBinds id pat)      -- The "business end"

	-- Creates bindings for *new* (polymorphic, overloaded) locals
	-- in terms of *old* (monomorphic, non-overloaded) ones.
	--
	-- See section 9 of static semantics paper for more details.
	-- (You can get a PhD for explaining the True Meaning
	--  of this last construct.)
\end{code}

What AbsBinds means
~~~~~~~~~~~~~~~~~~~
	 AbsBinds tvs
		  [d1,d2]
		  [(tvs1, f1p, f1m), 
		   (tvs2, f2p, f2m)]
		  BIND
means

	f1p = /\ tvs -> \ [d1,d2] -> letrec DBINDS and BIND 
				      in fm

	gp = ...same again, with gm instead of fm

This is a pretty bad translation, because it duplicates all the bindings.
So the desugarer tries to do a better job:

	fp = /\ [a,b] -> \ [d1,d2] -> case tp [a,b] [d1,d2] of
					(fm,gm) -> fm
	..ditto for gp..

	p = /\ [a,b] -> \ [d1,d2] -> letrec DBINDS and BIND 
				      in (fm,gm)

\begin{code}
nullMonoBinds :: MonoBinds id pat -> Bool

nullMonoBinds EmptyMonoBinds	     = True
nullMonoBinds (AndMonoBinds bs1 bs2) = nullMonoBinds bs1 && nullMonoBinds bs2
nullMonoBinds other_monobind	     = False

andMonoBinds :: MonoBinds id pat -> MonoBinds id pat -> MonoBinds id pat
andMonoBinds EmptyMonoBinds mb = mb
andMonoBinds mb EmptyMonoBinds = mb
andMonoBinds mb1 mb2 = AndMonoBinds mb1 mb2

andMonoBindList :: [MonoBinds id pat] -> MonoBinds id pat
andMonoBindList binds = foldr AndMonoBinds EmptyMonoBinds binds
\end{code}

\begin{code}
instance (Outputable id, Outputable pat) =>
		Outputable (MonoBinds id pat) where
    ppr mbind = ppr_monobind mbind


ppr_monobind :: (Outputable id, Outputable pat) => MonoBinds id pat -> SDoc
ppr_monobind EmptyMonoBinds = empty
ppr_monobind (AndMonoBinds binds1 binds2)
      = ppr_monobind binds1 $$ ppr_monobind binds2

ppr_monobind (PatMonoBind pat grhss locn)
      = sep [ppr pat, nest 4 (pprGRHSs False grhss)]

ppr_monobind (FunMonoBind fun inf matches locn)
      = pprMatches (False, ppr fun) matches
      -- ToDo: print infix if appropriate

ppr_monobind (VarMonoBind name expr)
      = sep [ppr name <+> equals, nest 4 (pprExpr expr)]

ppr_monobind (CoreMonoBind name expr)
      = sep [ppr name <+> equals, nest 4 (ppr expr)]

ppr_monobind (AbsBinds tyvars dictvars exports val_binds)
     = sep [ptext SLIT("AbsBinds"),
	    brackets (interpp'SP tyvars),
	    brackets (interpp'SP dictvars),
	    brackets (interpp'SP exports)]
       $$
       nest 4 (ppr val_binds)
\end{code}

%************************************************************************
%*									*
\subsection{@Sig@: type signatures and value-modifying user pragmas}
%*									*
%************************************************************************

It is convenient to lump ``value-modifying'' user-pragmas (e.g.,
``specialise this function to these four types...'') in with type
signatures.  Then all the machinery to move them into place, etc.,
serves for both.

\begin{code}
data Sig name
  = Sig		name		-- a bog-std type signature
		(HsType name)
		SrcLoc

  | ClassOpSig	name		-- Selector name
		(Maybe name)	-- Default-method name (if any)
		(HsType name)
		SrcLoc

  | SpecSig 	name		-- specialise a function or datatype ...
		(HsType name)	-- ... to these types
		(Maybe name)	-- ... maybe using this as the code for it
		SrcLoc

  | InlineSig	name		-- INLINE f
		SrcLoc

  | NoInlineSig	name		-- NOINLINE f
		SrcLoc

  | SpecInstSig (HsType name)	-- (Class tys); should be a specialisation of the 
				-- current instance decl
		SrcLoc

  | FixSig	(FixitySig name)		-- Fixity declaration


data FixitySig name  = FixitySig name Fixity SrcLoc
\end{code}

\begin{code}
sigsForMe :: (name -> Bool) -> [Sig name] -> [Sig name]
sigsForMe f sigs
  = filter sig_for_me sigs
  where
    sig_for_me (Sig         n _ _)    	  = f n
    sig_for_me (ClassOpSig  n _ _ _)  	  = f n
    sig_for_me (SpecSig     n _ _ _)  	  = f n
    sig_for_me (InlineSig   n     _)  	  = f n  
    sig_for_me (NoInlineSig n     _)  	  = f n  
    sig_for_me (SpecInstSig _ _)      	  = False
    sig_for_me (FixSig (FixitySig n _ _)) = f n

isFixitySig :: Sig name -> Bool
isFixitySig (FixSig _) = True
isFixitySig _	       = False

isClassOpSig :: Sig name -> Bool
isClassOpSig (ClassOpSig _ _ _ _) = True
isClassOpSig _			  = False
\end{code}

\begin{code}
instance (Outputable name) => Outputable (Sig name) where
    ppr sig = ppr_sig sig

instance Outputable name => Outputable (FixitySig name) where
  ppr (FixitySig name fixity loc) = sep [ppr fixity, ppr name]


ppr_sig (Sig var ty _)
      = sep [ppr var <+> dcolon, nest 4 (ppr ty)]

ppr_sig (ClassOpSig var _ ty _)
      = sep [ppr var <+> dcolon, nest 4 (ppr ty)]

ppr_sig (SpecSig var ty using _)
      = sep [ hsep [text "{-# SPECIALIZE", ppr var, dcolon],
	      nest 4 (hsep [ppr ty, pp_using using, text "#-}"])
	]
      where
	pp_using Nothing   = empty
	pp_using (Just me) = hsep [char '=', ppr me]

ppr_sig (InlineSig var _)
        = hsep [text "{-# INLINE", ppr var, text "#-}"]

ppr_sig (NoInlineSig var _)
        = hsep [text "{-# NOINLINE", ppr var, text "#-}"]

ppr_sig (SpecInstSig ty _)
      = hsep [text "{-# SPECIALIZE instance", ppr ty, text "#-}"]

ppr_sig (FixSig fix_sig) = ppr fix_sig
\end{code}

