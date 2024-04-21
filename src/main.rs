use actix_files::Files;
use actix_web::{web, App, Error, HttpResponse, HttpServer, Responder};
use reqwest;
use serde_json::Value;
use std::env;

#[actix_web::post("/query")]
async fn query(json: web::Json<Value>) -> Result<HttpResponse, Error> {
    let server_url = embryo::get_em_disco_url();
    let client = reqwest::Client::new();
    let query = match json.to_string().parse::<Value>() {
        Ok(parsed_json) => match parsed_json.get("query").and_then(|q| q.as_str()) {
            Some(q) => q.to_owned(),
            None => {
                return Ok(HttpResponse::BadRequest().finish());
            }
        },
        Err(_) => {
            return Ok(HttpResponse::BadRequest().finish());
        }
    };

    let response = client
        .post(&format!("{}/query", server_url))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(query)
        .send()
        .await;

    match response {
        Ok(res) => {
            let body = res.text().await.unwrap_or_else(|_| String::new());
            Ok(HttpResponse::Ok().body(body))
        }
        Err(_) => {
            Ok(HttpResponse::Ok().finish())
        }
    }
}

async fn start_server(embox_port: String) {
    let server = HttpServer::new(move || {
        App::new()
            .service(query)
            .route("/", web::get().to(index))
            .service(Files::new("/static", "src/static").prefer_utf8(true))
    })
    .bind(format!("0.0.0.0:{}", embox_port))
        .expect("Failed to bind address")
        .run();

    if let Err(err) = server.await {
        eprintln!("Server failed: {:?}", err);
    }
}

async fn index() -> impl Responder {
    let html = include_str!("templates/index.html");
    HttpResponse::Ok().body(html)
}

#[tokio::main]
async fn main() {
    let embox_port = env::var("embox_port").unwrap_or_else(|_| {
        let config_map = embryo::read_emergence_conf().unwrap_or_default();
        config_map
            .get("embox")
            .and_then(|em_disco| em_disco.get("port"))
            .map_or("8079".to_string(), |port| port.clone())
    });

    println!("Emergence Client V0.1.0");
    start_server(embox_port).await;
}

