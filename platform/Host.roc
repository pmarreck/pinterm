Host := [].{
	config! : () => List(I64)
	present! : List(U8) => List(U8)
	audio! : List(I16) => List(I16)
	log! : List(U8) => List(U8)
	control! : U8 => {}
	tick! : () => List(U8)
}
