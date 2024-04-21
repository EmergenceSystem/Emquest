function submitForm(event) {
    event.preventDefault();

    const searchQuery = document.getElementById("searchQuery").value;
    
    fetch('/query', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({ query: searchQuery }),
    })
    .then(response => {
        if (!response.ok) {
            throw new Error('Network response was not ok');
        }
        return response.json();
    })
    .then(data => {
        const searchResultList = document.getElementById("searchResults");
        searchResultList.innerHTML = ''; // Clear the previous search results
        
        data.embryo_list.forEach(item => {
            const listItem = document.createElement('li');
            const url = item.properties.url || 'URL not available';
            const resume = item.properties.resume || 'Resume not available';
            const link = document.createElement('a');
            link.href = url;
            link.textContent = url;
            listItem.appendChild(link);
            
            const paragraph = document.createElement('p');
            paragraph.textContent = resume;
            listItem.appendChild(paragraph);
            searchResultList.appendChild(listItem);
        });
    })
    .catch(error => {
        console.error('Error:', error);
    });
}

document.getElementById("searchForm").addEventListener("submit", submitForm);
