import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MongoBox Jukebox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Current playing track
         _buildNowPlaying(context),
          // Song request interface
          _buildRequestForm(),
          // Queue list
          _buildQueueList(),
        ],
      ),
    );
  }

 Widget _buildNowPlaying(BuildContext context) {  // Add context parameter
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          const Text('NOW PLAYING', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Song Name - Artist',
            style: Theme.of(context).textTheme.titleLarge,  // Now context is available
          ),
        ],
      ),
    ),
  );
}


  Widget _buildRequestForm() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              labelText: 'Search for songs',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {}, // Implement search
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {}, // Implement song request
            child: const Text('Request Song'),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueList() {
    return Expanded(
      child: ListView.builder(
        itemCount: 10, // Replace with actual queue length
        itemBuilder: (context, index) => ListTile(
          leading: Text('${index + 1}'),
          title: Text('Song $index'),
          subtitle: Text('Artist $index'),
          trailing: IconButton(
            icon: const Icon(Icons.thumb_up),
            onPressed: () {}, // Implement voting
          ),
        ),
      ),
    );
  }
}