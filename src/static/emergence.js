let socket = new WebSocket("ws://"+window.location.host+"/ws/");

socket.onopen = function () {
    console.log("WebSocket open");
};

socket.onmessage = function (event) {
    console.log("Received message from server:", event.data);
};

socket.onerror = function (error) {
    console.error("WebSocket error:", error);
}; 

function submitForm(event) {
    event.preventDefault(); 

    const searchQuery = document.getElementById("searchQuery").value;
    if (socket.readyState === WebSocket.OPEN) {
        socket.send(searchQuery);
    } else {
        console.error("WebSocket connection is not open.");
    }
}
document.getElementById("searchForm").addEventListener("submit", submitForm);
