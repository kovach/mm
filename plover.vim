syn keyword Keyword module import extern static inline __C__
syn keyword Keyword struct type storing
syn keyword Keyword mat vec for in out inout
syn keyword Keyword while if then else specialize
syn keyword Keyword   True False Void T _ __
syn keyword Keyword   and or return assert

syntax match comm "--.*$"
syntax match sep "\v\(.*::.*\)"
syntax match semi "\;"
syntax match fntype "::.*:="

highlight link comm Comment
highlight link sep Function
highlight link semi PreProc
highlight link fntype TypeDef
