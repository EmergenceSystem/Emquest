use actix_files::Files;
use actix_web::{App, web, Responder, HttpResponse, HttpServer};
use serde::Deserialize;
use reqwest;
use textwrap::wrap;
use std::env;
use embryo::EmbryoList;

#[derive(Deserialize)]
struct FormData {
    search_query: String,
}

async fn index() -> impl Responder {
    let html = include_str!("templates/index.html");
    actix_web::HttpResponse::Ok().body(html)
}

async fn search(form: web::Json<FormData>) -> HttpResponse {
    let query = &form.search_query;
    if !query.trim().is_empty() {
        let embox_url = match env::var("embox_url") {
            Ok(url) => url,
            Err(_) => {
                let config_map = embryo::read_emergence_conf().unwrap_or_default();
                match config_map.get("embox").and_then(|em_disco| em_disco.get("url")) {
                    Some(url) => url.clone(),
                    None => "http://localhost:8079/embox".to_string(),
                }
            },
        };

        let json = format!("{{\"embox_url\": \"{}\", \"query\" : \"{}\"}}", embox_url, query.trim_end().to_string());
        let server_url = embryo::get_em_disco_url();
        let client = reqwest::Client::new();
        let _ = match client
            .post(&format!("{}/query", server_url))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(json)
            .send()
            .await {
                Ok(_) => (),
                Err(err) => {
                    eprintln!("Failed to send HTTP request to {} : \n\t{}", server_url, err);
                }
            };
    }

    HttpResponse::Ok().into()
}

#[actix_web::post("/embox")]
async fn embox(json: web::Json<serde_json::Value>) -> impl Responder {
    let filter_response: Result<EmbryoList, _> = serde_json::from_str(json.to_string().as_str());

    match filter_response {
        Ok(filter_response) => {
            for embryo in filter_response.embryo_list {
                let mut url = String::new();
                let mut resume = String::new();
                for (name, value) in &embryo.properties {
                    match name.as_str() {
                        "url"  => {
                            url=value.clone();
                        },
                        "resume" => {
                            resume=value.clone();
                        }
                        _ => { }
                    }
                }
                let term_width = match term_size::dimensions() {
                    Some((w, _)) => w as usize - 10,
                    None => 80,
                };

                let wrapped_resume = wrap(&resume, term_width - 1)
                    .iter()
                    .map(|line| format!("\t{}", line))
                    .collect::<Vec<_>>()
                    .join("\n");
                println!("{}\n{}", url, wrapped_resume);
            }
        }
        Err(_) => {
            let uri = json.to_string().trim_matches('"').to_owned();
            println!("{}", uri);
        }
    }
    HttpResponse::Ok().body("Embox OK")
}

async fn start_server(embox_port: String) {
    let server = HttpServer::new(|| {
        App::new().service(embox)
            .route("/", web::get().to(index))
            .route("/search", web::post().to(search))
            .service(Files::new("/static", "src/static").prefer_utf8(true))
    })
    .bind(format!("0.0.0.0:{}", embox_port))
        .expect("Failed to bind address")
        .run();
    server.await.expect("Server failed");
}

#[tokio::main]
async fn main() {

    let embox_port = match env::var("embox_port") {
        Ok(url) => url,
        Err(_) => {
            let config_map = embryo::read_emergence_conf().unwrap_or_default();
            match config_map.get("embox").and_then(|em_disco| em_disco.get("port")) {
                Some(port) => port.clone(),
                None => "8079".to_string(),
            }
        },
    };
    

    println!("Emergence Client V0.1.0");
    start_server(embox_port).await;
}

