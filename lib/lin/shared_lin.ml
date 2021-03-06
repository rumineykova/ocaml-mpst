open Concur_shims
open Mpst.Internal

let (let*) = IO.bind

include Shared.Make(Dyn_lin.NoCheck)(Combinators_lin.Lin)

let accept sh r =
  {Linocaml.__m=(fun lpre ->
       let* ep = accept sh r in
       IO.return (lpre, {Linocaml.__lin=ep})
     )}

let connect sh r =
  {Linocaml.__m=(fun lpre ->
       let* ep = connect sh r in
       IO.return (lpre, {Linocaml.__lin=ep})
     )}
