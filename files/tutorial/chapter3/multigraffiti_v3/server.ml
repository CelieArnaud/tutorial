open HTML5.M
open Common
open Lwt

module My_appl =
  Eliom_output.Eliom_appl (
    struct
      let application_name = "graffiti"
    end)

let rgb_from_string color = (* color is in format "#rrggbb" *)
  let get_color i = (float_of_string ("0x"^(String.sub color (1+2*i) 2))) /. 255. in
  try get_color 0, get_color 1, get_color 2 with | _ -> 0.,0.,0.

let launch_server_canvas () =
  let bus = Eliom_bus.create Json.t<messages> in
  
  let draw_server, image_string =
    let surface = Cairo.image_surface_create Cairo.FORMAT_ARGB32 ~width ~height in
    let ctx = Cairo.create surface in
    ((fun ((color : string), size, (x1, y1), (x2, y2)) ->

      (* Set thickness of brush *)
      Cairo.set_line_width ctx (float size) ;
      Cairo.set_line_join ctx Cairo.LINE_JOIN_ROUND ;
      Cairo.set_line_cap ctx Cairo.LINE_CAP_ROUND ;
      let red, green, blue =  rgb_from_string color in
      Cairo.set_source_rgb ctx ~red ~green ~blue ;

      Cairo.move_to ctx (float x1) (float y1) ;
      Cairo.line_to ctx (float x2) (float y2) ;
      Cairo.close_path ctx ;
      
      (* Apply the ink *)
      Cairo.stroke ctx ;
     ),
     (fun () ->
       let b = Buffer.create 10000 in
       (* Output a PNG in a string *)
       Cairo_png.surface_write_to_stream surface (Buffer.add_string b);
       Buffer.contents b
     ))
  in
  let _ = Lwt_stream.iter draw_server (Eliom_bus.stream bus) in
  bus,image_string

let graffiti_info = Hashtbl.create 0

let get_bus_image (name:string) =
  (* create a new bus and image_string function only if it did not exists *)
  try
    Hashtbl.find graffiti_info name
  with
    | Not_found ->
      let bus,image_string = launch_server_canvas () in
      Hashtbl.add graffiti_info name (bus,image_string);
      (bus,image_string)

let main_service = Eliom_services.service ~path:[""]
  ~get_params:(Eliom_parameters.unit) ()
let multigraffiti_service = Eliom_services.coservice ~fallback:main_service
  ~get_params:(Eliom_parameters.string "name") ()

let choose_drawing_form () =
  Eliom_output.Html5.get_form ~service:multigraffiti_service
    (fun (name) ->
      [p [pcdata "drawing name: ";
          Eliom_output.Html5.string_input ~input_type:`Text ~name ();
          br ();
          Eliom_output.Html5.string_input ~input_type:`Submit ~value:"Go" ()
         ]])

let graffiti_oclosure =
  unique (HTML5.M.script
            ~a:[HTML5.M.a_src (HTML5.M.uri_of_string "./graffiti_oclosure.js")
               ] (HTML5.M.pcdata ""))

let connection_service =
  Eliom_services.post_coservice' ~post_params:
    (let open Eliom_parameters in (string "name" ** string "password")) ()
let disconnection_service = Eliom_services.post_coservice' ~post_params:Eliom_parameters.unit ()
let create_account_service = 
  Eliom_services.post_coservice ~fallback:main_service ~post_params:
  (let open Eliom_parameters in (string "name" ** string "password")) ()

let username = Eliom_references.eref ~scope:Eliom_common.session None
let users = ref ["titi","tata";"test","test"]
let check_pwd name pwd = try List.assoc name !users = pwd with Not_found -> false

let () = Eliom_output.Action.register
  ~service:create_account_service
  (fun () (name, pwd) ->
    users := (name, pwd)::!users;
    Lwt.return ())

let () = Eliom_output.Action.register
  ~service:connection_service
  (fun () (name, password) ->
    if check_pwd name password
    then Eliom_references.set username (Some name)
    else Lwt.return ())

let () =
  Eliom_output.Action.register
    ~service:disconnection_service
    (fun () () -> Eliom_state.discard ~scope:Eliom_common.session ())

let disconnect_box () =
  Eliom_output.Html5.post_form disconnection_service
    (fun _ -> [p [Eliom_output.Html5.string_input
                  ~input_type:`Submit ~value:"Log out" ()]]) ()

let login_name_form service button_text =
  Eliom_output.Html5.post_form ~service
    (fun (name1, name2) ->
      [p [pcdata "login: ";
          Eliom_output.Html5.string_input ~input_type:`Text ~name:name1 ();
          br ();
          pcdata "password: ";
          Eliom_output.Html5.string_input ~input_type:`Password ~name:name2 ();
          br ();
          Eliom_output.Html5.string_input ~input_type:`Submit ~value:button_text ()
         ]]) ()



let create_page content =
  (html
     (head
	(title (pcdata "Graffiti"))
        [
          HTML5.M.link ~rel:[ `Stylesheet ]
            ~href:(HTML5.M.uri_of_string"./css/graffiti.css")
            ();
          HTML5.M.link ~rel:[ `Stylesheet ]
            ~href:(HTML5.M.uri_of_string"./css/common.css")
            ();
          HTML5.M.link ~rel:[ `Stylesheet ]
            ~href:(HTML5.M.uri_of_string"./css/hsvpalette.css")
            ();
          HTML5.M.link ~rel:[ `Stylesheet ]
            ~href:(HTML5.M.uri_of_string"./css/slider.css")
            ();
          graffiti_oclosure
        ]
     )
     (body content))

let default_content () =
  [h1 [pcdata "Welcome to Multigraffiti"];
   h2 [pcdata "log in"];
   login_name_form connection_service "Connect";
   h2 [pcdata "create account"];
   login_name_form create_account_service "Create account";]

module Connected_translate =
struct
  type page = string -> [ HTML5_types.body_content_fun ] HTML5.M.elt list Lwt.t
  let translate page =
    Eliom_references.get username >>= function
      | None -> Lwt.return (create_page (default_content ()))
      | Some username -> page username >|= fun v -> 
        create_page ((disconnect_box ())::v)
end

module Connected =
  Eliom_output.Customize (struct
    type options = Eliom_output.appl_service_options
    type return = My_appl.return 
    type page = Eliom_output.Html5.page
    type result = My_appl.result
  end) (My_appl) (Connected_translate)

let ( !% ) f = fun a b -> return (fun c -> f a b c)

let () = Connected.register ~service:main_service 
  !% (fun () () username ->
    Lwt.return [h1 [pcdata ("Welcome to Multigraffiti " ^ username)];
		choose_drawing_form ()])

